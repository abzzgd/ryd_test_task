package Snip::Controller::Snippet;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Base -base;
use Mojo::UserAgent;
use Mojo::Upload;
use Mojo::Promise;
use Mojo::AsyncAwait;


sub show_all {
  my $self = shift;
  my $snips_on_page = 3;
  my $total_snips = $self->pg->db->select('snippets','count(*)',)->hash->{count};
  my $cur_page = $self->param('page') || 1;
  my $ofs = $snips_on_page*($cur_page -1); 
  my $total_pages = $total_snips/$snips_on_page;

  my $txt = $self->pg->db->query(
    "select * from
      (select
      s.id,t,f_content,
      count(*) over (partition by snip_id) as count,
      row_number() over (partition by snip_id) as num
    
      from files f
      join
      (select * from snippets where pub = '1' order by t limit ? offset ?) s
      on snip_id = s.id
      ) ff
    where num = 1", $snips_on_page, $ofs 
  )->hashes->to_array;

  my $lngs = $self->pg->db->query(
    "select lang,count(*) from snippets group by lang"
  )->hashes->to_array;

  $self->render(
    txt          => $txt,
    lngs         => $lngs,
    current_page => $cur_page,
    total_pages  => ($total_pages - int($total_pages))? int($total_pages)+1 : $total_pages,
  );

}

sub show {
  my $self = shift;
  my $snip_id;
  my $db = $self->pg->db;
  if ($self->param('id')) {
    $snip_id = $self->param('id');
    # checking if snippet is not public
    my $public = $db->select('snippets','pub',{id => $self->param('id')})->hash->{'pub'};
    if ($public != '1') {
      $self->redirect_to('show_all_snips');
      return;
    }
  }
  # secret link  
  if ($self->param('hsh')) {
    $snip_id = $db->select('snippets','id',{pub => $self->param('hsh')})->hash->{'id'};
  }
  # 'show selected snip', 
  $self->render( 
    txt => $db->select('files', '*', {snip_id => $snip_id})->hashes->to_array,
  );
}

sub create {
  my $self = shift;
  my $err_message = $self->param('err_message');
  $self->render( err_message => $err_message ); 
}

sub save {
  my $self = shift;

  my $v = $self->_validation;
  if (!(scalar @{$v->passed})) {
    $self->redirect_to('create');
    return;
  }

  my $lang = $self->param('lang');
  if ($lang eq 'none') { $lang = $self->_language_from_filename; } 

  async get_f_content => sub {
    my $url  = shift;
    my $tx = await $self->ua->get_p($url);
    return $tx->result->text;
  };

  async f_urls => sub {
    my $urls = shift;
    my $ref_f_contents = shift;
    my @promises = map {get_f_content($_);}@$urls;
    push @$ref_f_contents, map {$_->[0]} await Mojo::Promise->all(@promises);
    return $ref_f_contents;
  };
 
  my @f_names;
  my @f_contents = @{$v->every_param('f_content')};
  @f_names = @{$v->every_param('f_name')} if @f_contents;
  foreach (@{$v->every_param('f_opn')}) {
    push @f_contents, $_->slurp; 
    push @f_names, $_->filename; 
  }
  if (@{$v->every_param('f_url')}) {
    push @f_names, map {/[^\/]*$/; $&;} @{$v->every_param('f_url')}; 
    # non-blocking way
    $self->render_later;
    f_urls($v->every_param('f_url'),\@f_contents)->then(sub { 
      my $ref_f_contents = shift;
      if ($lang eq 'none') { 
        $lang = $self->_language_from_shebang($ref_f_contents);
      }
      $self->_insert_new_snip($lang, $ref_f_contents, \@f_names);
    })->wait;
  } else {
    # ordinary way
    if ($lang eq 'none') { 
      $lang = $self->_language_from_shebang(\@f_contents);
    }
    $self->_insert_new_snip($lang, \@f_contents, \@f_names);
  }
}

sub _insert_new_snip {
  my ($self, $lang, $ref_f_content, $ref_f_names) = @_;
  my $db = $self->pg->db;
  my $snip_id;
  eval {
      my $tx = $db->begin;
      $snip_id = $db->insert(
        'snippets',
        {t => \'now()', lang => $lang, pub => 1},
        {returning => 'id'}
      )->hash->{id};
      for (@$ref_f_content) {
        $db->insert('files', {f_content => $_, f_name => shift @$ref_f_names, snip_id => $snip_id});
      }
      $tx->commit;
  };
  if ($@) {
    $self->redirect_to('create', err_message => $@);
  } else {
    $self->redirect_to('show_snip', id => $snip_id);
  }
}

sub _validation {
  my $self = shift;
  my $v = $self->validation;
  $v->validator->add_check(emptyUpload => sub {
    my $v = shift;
    my $name = $v->topic;
    if (!$v->param->filename) {
      $v->output->{$name} = undef;
    }
    return $v;
  });

#  $v->required('f_name');
  $v->required('f_content');
  $v->required('f_url');
  $v->optional('f_opn')->emptyUpload;
  
  return $v;
}

sub _language_from_filename {
  my $self = shift;
  my %list = qw(cpp c++ py python pl perl java java js javascript);
  my $lng; 
  for my $t (map /\.(\w*)$/, @{$self->every_param('f_url')}) {
    return $list{$lng} if ($lng) = grep /^$t$/, keys %list; 
  }  
  
  for my $t (map $_->filename =~ /\.(\w*)$/, @{$self->every_param('f_opn')}) {
    return $list{$lng} if ($lng) = grep /^$t$/, keys %list; 
  }
  return 'none';
}

sub _language_from_shebang {
  my $self           = shift;
  my $ref_f_contents = shift;
  my @list           = qw(c++ python perl java javascript);
  foreach my $f_content (@$ref_f_contents) {
    $f_content =~ /#!.*\/(\w+)/g;
    (my $lng) = grep (/^$1$/, @list); 
    return $lng if $lng;
  }
  return 'none';
}

1;

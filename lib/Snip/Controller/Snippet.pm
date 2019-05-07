package Snip::Controller::Snippet;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Base -base;
use Mojo::UserAgent;
use Mojo::Upload;

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

  if (scalar @{$v->passed}) {
    my $db = $self->pg->db;
    my $snip_id;
    eval {
      my $tx = $db->begin;
      $snip_id = $db->insert(
        'snippets',
        {t => \'now()', lang => $self->param('lang'), pub => 1},
        {returning => 'id'}
      )->hash->{id};
      foreach my $field (@{$v->passed}) {
        if ($field eq 'f_url') {
          my $ua = Mojo::UserAgent->new();
 
          foreach (@{$v->every_param($field)}) {
            my $f_content = $ua->get($_)->res->text;
            /[^\/]*$/;
            $db->insert('files', {f_content => $f_content, f_name=> $&, snip_id => $snip_id});
          }  
        } 

        if (($field eq 'f_opn') && $v->param($field)->filename) {

          foreach (@{$v->every_param($field)}) {
            $db->insert('files', {f_content => $_->slurp, f_name => $_->filename, snip_id => $snip_id});
          }

        } 
        if ($field eq 'f_content') {

          foreach (0..$#{$v->every_param($field)}) {
            my $f_content = $v->every_param($field)->[$_];
            $db->insert('files', {f_content => $f_content, snip_id => $snip_id});
          }
        }
      }
      $tx->commit;
    };
    if ($@) {
      $self->redirect_to('create', err_message => $@);
    } else {
      $self->redirect_to('show_snip', id => $snip_id);
    }

  } else {
    $self->redirect_to('create');
  } 
}

sub _validation {
  my $self = shift;

  my $v = $self->validation;
#  $v->required('f_name');
  $v->required('f_content');
  $v->required('f_url');
  $v->required('f_opn');
  
  return $v;
}

1;

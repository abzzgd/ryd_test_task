package Snip::Controller::Snippet;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Base -base;
use Mojo::UserAgent;
use POSIX qw(strftime);

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
      (select * from snippets order by t limit $snips_on_page offset $ofs ) s
      on snip_id = s.id
      ) ff
    where num = 1"
  )->hashes->to_array;

  my $lngs = $self->pg->db->query(
    "select lang,count(*) from files group by lang"
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
  my $snip_id = $self->param('id'); 

  # 'show selected snip', 
  $self->render( 
    txt => $self->pg->db->select('files', '*', {snip_id => $snip_id})->hashes->to_array,
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
    my $datestring = strftime "%Y-%m-%d %H:%M:%S", localtime;
    my $db = $self->pg->db;
    my $snip_id;
    eval {
      my $tx = $db->begin;
      $snip_id = $db->insert('snippets', {t => $datestring}, {returning => 'id'})->hash->{id};

      foreach my $field (@{$v->passed}) {
        if ($field eq 'f_url') {
          my $ua = Mojo::UserAgent->new();
 
          foreach (0..$#{$v->every_param($field)}) {
            my $f_content = $ua->get($v->every_param($field)->[$_])->res->text;
            my $lang      = $self->every_param('lang_url')->[$_];
            $db->insert('files', {f_content => $f_content, lang => $lang, snip_id => $snip_id});
          }  

        } else {         # $field eq 'f_content' || 'f_opn'

          foreach (0..$#{$v->every_param($field)}) {
            my $f_content = $v->every_param($field)->[$_];
            my $lang      = $self->every_param('lang')->[$_];
            $db->insert('files', {f_content => $f_content, lang => $lang, snip_id => $snip_id});
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
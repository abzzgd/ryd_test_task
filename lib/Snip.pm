package Snip;
use Mojo::Base 'Mojolicious';
use Mojo::Pg;

sub startup {
  my $self = shift;
  my $config = $self->plugin('Config');
  $self->secrets($config->{secrets});
  $self->plugin('bootstrap_pagination');

  $self->helper(pg => sub { state $pg = Mojo::Pg->new(shift->config('pg')) });

  my $r = $self->routes;
  $r->get('/')->to('snippet#show_all')->name('show_all_snips');
  $r->get('/create')->to('snippet#create')->name('create');
  $r->post('/')->to('snippet#save')->name('save');
  $r->get('/snip/:id')->to('snippet#show')->name('show_snip');
}

1;

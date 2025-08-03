package Melies::Controller::Films;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use List::Util qw/min first/;

sub list ($c) {
    my $films = $c->db->query("select file, files.id as wd_id, film_key_properties.* " . 
			      "from files left join film_key_properties on files.id = film_key_properties.id " .
			      "where not files.blacklist or files.blacklist is null " .
			      "order by file;" );
    $films = $films->expand->hashes;
    $films->each(sub {
		     $_->{release_dates} = min map { /(\d{4,4})/; $1 } split /\,\s*/, ($_->{release_dates} || "");
		     $_->{titles} = first { 1 } map { $_  } split /\)\,\s*/, ($_->{titles} || "");
		 });

    $c->stash(items => $films, fields => [qw/file titles directors release_dates wd_id/]);
    $c->render(template => 'films');
};

sub search ($c) {
    unless ($c->req->param("q")) {
	$c->render(template => 'films/search');
    } else {
	my $films = $c->db->query("select file, files.id as wd_id, film_key_properties.* " . 
				    "from files left join film_key_properties on files.id = film_key_properties.id " .
				    "where files.id in (select distinct id from film_properties where value like ?) " . "order by file;",
				    join $c->param("q"), "%", "%");
	$films = $films->expand->hashes;
	$films->each(sub {
			 $_->{release_dates} = min map { /(\d{4,4})/; $1 } split /\,\s*/, $_->{release_dates};
			 $_->{titles} = first { 1 } map { $_  } split /\)\,\s*/, $_->{titles};
		     });
	$c->stash(items => $films, fields => [qw/file titles directors release_dates wd_id/]);
	$c->render(template => 'films');
    }
};



1;

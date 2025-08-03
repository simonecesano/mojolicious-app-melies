#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use Mojo::SQLite;
use Mojo::Util qw/dumper encode decode/;

use List::Util qw/min first/;
use autobox::Lookup;

plugin "EasyLibs";
plugin "Wikidata";
plugin "MoreLog";

my $sql = Mojo::SQLite->new('sqlite:./films.db');

helper db => sub { state $db = $sql->db };

get '/' => sub { shift->redirect_to("/films") };


(get '/films/search')->to("Films#search");
(get '/films')->to("Films#list");

get '/films/:film_id' => [ film_id => qr/Q.+/ ] => sub {
    my $c = shift;
    my $id = $c->param('film_id');
    $c->log->info($id =~ qr/./); 
    $c->render(text => "Valid ID: $id");
};



get '/films/curate' => sub ($c) {
    my $films = $sql->db->query("select file from files where id = '' or id is null order by file;" )->expand->hashes;
    $c->stash(items => $films, fields => [qw/file/]);
    $c->render(template => 'films_curate');
};

post '/films/curate' => sub ($c) {
    $c->log->info(dumper $c->req->body_params->to_hash);
    $sql->db->insert('files', $c->req->body_params->to_hash,
		     {on_conflict => [ file => { id => $c->param("id") }]});

    $c->render(text => sprintf '<td>%s</td><td>%s</td>', $c->param("file"), $c->param("id"));
};


post '/films/properties/:film_id' => sub ($c) {
    my $film_id = $c->stash("film_id");;
    my $stdout;
    {
	local *STDOUT;  # Temporarily replace STDOUT
	open STDOUT, '>', \$stdout or die "Can't redirect STDOUT: $!";
	local @ARGV = ($film_id);  # Override @ARGV inside the block
	do './get_film_properties.pl';  # Execute script as if it was called with arguments
	return $c->render(text => "Error: $@", status => 500) if $@;
    }
    for (split /\n/, $stdout) {
	my %v; @v{qw/id property_id property value/} = split /\t/, decode "UTF-8", $_;
	my $s = $c->db->select('film_properties', undef, { id => $v{id}, property_id => $v{property_id} })->hashes->size;
	if ($s) {
	    $c->db->update('film_properties', \%v, { id => $v{id}, property_id => $v{property_id} })
	} else {
	    $c->db->insert('film_properties', \%v);
	}
    }
    $c->render(text => $stdout);
};

get '/films/*file' => sub {
    my $c = shift;
    my $id = $c->param('file');
    $c->log->info($id =~ qr/./);
    $c->render(text => "File: $id");
};

get "/data/search" => sub ($c) {
    unless ($c->req->param("q")) {
	$c->render(template => 'data/search');
    } else {
	$c->render_later;
	$c->log->info($c->param("q"));
	$c->log->info($c->req->headers->referrer);
	$c->stash(referrer => Mojo::URL->new($c->req->headers->referrer)->path);
	$c->search_wikidata_p($c->param("q"), ["Q11424", "Q5398426"])
	    ->then(sub {
		       if (scalar @_ == 1) {
			   my $films = $c->db->query("select file from files where id = '' or id is null and file like ?;",
						     sprintf "%%%s%%", $c->param("q") )->expand->hashes;
			   if (
			       $films->size == 1 &&
			       $c->param("q") eq $films->first->{file} =~ s/\.[^\.]+//r
			      ) {
			       $c->log->printf("Updating film id to %s", $_[0]->{title});
			       $c->db->update("files", { id => $_[0]->{title} }, { file => $films->first->{file} });
			   }
			   else {
			       $c->log->printf("Getting %s from db", $_[0]->{title});
			   }
		       }

		       $c->stash("entities" => \@_);
		       $c->render(template => 'data/list');
		   })
	    ->catch(sub {
			my $err = shift;
			$c->log->info($err);
			$c->reply->exception($err);
		    })
    }
};

use Clone 'clone';

get "/data/:id" => sub ($c) {
    $c->render_later;
    $c->stash("fields" => [qw/P1476 P57 P136 P495 P577 P364 P58 P161 P344 P1040/]);
    $c->get_wikidata_p($c->stash("id"))
	->then(sub {
		   $c->stash("info", { $_[0]->map(sub { $_->{id} => $_ })->@* });
		   # $c->log->dump($c->stash("info"));

		   for ($c->stash("fields")->@*) {
		       my $v = clone $c->stash("info")->{$_};
		       $v->{values} = (join ", ", $v->{values}->@*) if (ref $v->{values} eq "Mojo::Collection");

		       my $s = $c->db->select('film_properties', undef, { id => $c->stash("id") , property_id => $_ })->hashes->size;
		       if ($s) {
			   $c->log->info("film_properties ok")
			   # $c->db->update('film_properties', \%v, { id => $v{id}, property_id => $v{property_id} })
		       } else {
			   $c->db->insert('film_properties', {
							      id => $c->stash("id"),
							      property_id => $_,
							      property => $v->{description},
							      value => $v->{values}
							     });
		       }
		   }
		   $c->render(template => "data/detail");
	       })
};

app->start;

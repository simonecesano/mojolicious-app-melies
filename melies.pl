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

__DATA__
@@ index.html.ep
% layout 'default';
% title 'Welcome';
<h1>Welcome to the Mojolicious real-time web framework!</h1>
@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><%= title %></title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/htmx/2.0.4/htmx.min.js"
	    integrity="sha512-2kIcAizYXhIn8TzUvqzEDZNuDZ+aW7yE/+f1HJHXFjQcGNfv1kqzJSTBRBSlOgp6B/KZsz1K0a3ZTqP9dnxioQ=="
	    crossorigin="anonymous" referrerpolicy="no-referrer"></script>
    <style>
      body * { font-family: "Courier"; letter-spacing: -1.25px; word-spacing: -0.2rem;  }
      body { height: 100vh; width: 100vw; margin: 0; padding: 0 }
      #container { margin-left: 8em; margin-right: 8em }
      button { border: none; border-radius: 0px; padding: 8px;
      
  display: inline-flex;
  justify-content: center;
  align-items: center};
    </style>
  </head>
  <body><%= content %></body>
</html>
@@ film.html.ep

@@ films.html.ep
% layout 'default';
%= include 'menu';
<style>
  #container { margin-left: 8em; margin-right: 8em }
  #films td, #films th { border-bottom: thin solid grey; vertical-align: top; width: 36em; padding-left: 6px; padding-right: 6px; padding-top: 3px; padding-bottom: 3px }
  #films tr td:nth-of-type(1) { width: 24em}
  #films tr td.release_dates { width: 6em}
  #films tr td.wd_id { width: 6em}
  #films tr th { text-align: left }
</style>
<script>
    document.addEventListener("DOMContentLoaded", function () {
	document.querySelectorAll("#films td")
	    .forEach(td => {
		td.addEventListener("click", function () {
		    var wd_id = td.parentNode.querySelector(".wd_id").innerHTML;
		    if (wd_id) {
			window.location.href = "<%= url_for("/data/") %>" + (td.parentNode.querySelector(".wd_id").innerHTML)
		    } else {
			document.querySelector("dialog#edit_modal #filename").innerHTML = td.parentNode.querySelector(".file").innerHTML;
			document.getElementById('edit_modal').showModal();
		    }
		})
	    })
    })
    </script>
    <div id="container">
<table id="films">
  <tr>
    % for my $field ($fields->@*) {
    <th><%= $field %></th>
    % }
  </tr>  
  % for my $item ($items->@*) {
  <tr>
    % for my $field ($fields->@*) {
    <td class="<%= $field %>"><%= $item->{$field} %></td>
    % }
  </tr>
  % }
</table>    
%= include 'edit_modal'
@@ films_curate.html.ep
% layout 'default';
%= include 'menu';
<style>
  #container { margin-left: 8em; margin-right: 8em }
</style>
<div id="container">
<table>
% for my $item ($items->@*) {
  <tr>
    % for my $field ($fields->@*) {
    <td class="<%= $field %>"><%= $item->{$field} %></td>
    % }
    <td>
      <input class="film_id" type="text">
      <button>search</button>
      <button
	hx-post="/films/curate"
	hx-target="closest tr"
	hx-include="closest tr"
	hx-vals='js:{ 
                      id: event.target.closest("tr").querySelector("input.film_id").value, 
                      file: event.target.closest("tr").querySelector("td.file").innerHTML 
                }'
	>update</button>
      <button>blacklist</button>
    </td>
  </tr>
  % }
</table>
</div>

@@ search_style.html.ep
<style>
#container { display: flex; height: 100%; margin-top: -64px; padding: 0; flex-direction: column; justify-content: center; align-items: center; 0 }
        input { width: 300px; padding: 6px; text-align: center; }
        .buttons { margin-top: 6px; display: flex; gap: 10px; }
        button { width: 150px; cursor: pointer; border: none; /* Remove border */ background-color: #ddd;
		 text-align: center; display: flex; justify-content: center; align-items: center;
		 height: 40px; /* Fixed height for vertical centering */
		 padding: 6px;
		 cursor: pointer;
		 vertical-align: middle; }
</style>
@@ films/search.html.ep
% layout 'default';
%= include 'search_style';
%= include 'menu';
<div id="container">
<form action="/films/search" method="GET">
  <input name="q" type="text" placeholder="Enter search text">
  <div class="buttons">
    <button>Search</button>
    <button>Clear</button>
  </div>
  </form>
</div>  
@@ data/search.html.ep
% layout 'default';
%= include 'search_style';
%= include 'menu';
<div id="container">
<form action="/data/search" method="GET">
  <input name="q" type="text" placeholder="Enter search text">
  <div class="buttons">
    <button>Search</button>
    <button>Clear</button>
  </div>
  </form>
</div>  
@@ menu.html.ep
<style>
  .navbar {
font-weight: bold;
    display: flex;
    background-color: #333;
    padding: 10px 20px;
    margin-top: 0px;
    margin-bottom: 24px;
}

.navbar a {
    color: white;
    padding: 8px 16px;
    text-decoration: none;
    margin-right: 10px;
}

.navbar a:hover {
    background-color: #575757;
    border-radius: 0px;
}
</style>
<nav class="navbar">
  <a href="/films">All Films</a>
  <a href="#browse">Browse</a>
  <a href="/films/search">Search</a>
  <a href="/films/curate">Curate</a>
</nav>
@@ edit_modal.html.ep
 <style>
    dialog {
      padding: 0px;
      border: none;
    border-radius: 0;

    max-width: 33.33vw;   /* 1/3 of viewport width */
    max-height: 33.33vh;  /* 1/3 of viewport height */
    overflow: auto;       /* allows scrolling if content exceeds bounds */    
    }

    dialog::backdrop {
      background: rgba(0,0,0,0.5);
    }
  .modal-header {
    background: #000;
    color: white;
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    font-weight: bold;
  }

  .modal-header .close-btn {
    background: none;
    border: none;
    color: white;
    font-size: 20px;
    cursor: pointer;
    user-select: none;
    outline: none;
  }
    .modal-body {
    margin: 12px
  }

  </style>
  <dialog id="edit_modal">
  <div class="modal-header">
    <span>Edit</span>
    <button class="close-btn" id="closeBtn" hx-on:click="this.closest('dialog').close()">&#x2715;</button>
    </div>
    <div class="modal-body">
    <p>Edit information for:<br/><span id="filename"></span></p>
    <button hx-on:click="{
                          const filename = this.parentNode.querySelector('#filename').innerHTML.replace(/\.[^\.]+$/, '')
                          const base_url = &quot;<%= url_for("/data/search/") %>&quot;
                          window.location.href = base_url + &quot;?q=&quot; + filename
                          this.closest('dialog').close()
                         }"
	    >Search Id</button>
    <button hx-on:click="{
                          const filename = this.parentNode.querySelector('#filename').innerHTML.replace(/\.[^\.]+$/, '')
                          const base_url = &quot;<%= url_for("/data/search/") %>&quot;
                          this.closest('dialog').close()
                         }"
	    >Blacklist</button>
    <button hx-on:click="this.closest('dialog').close()" id="closeBtn">Close</button>
    </div>
  </dialog>
@@ data/list.html.ep
% unless ((param "mode") eq "snippet") {
% layout 'default';
%= include 'menu';
<style>
  #container { margin-left: 8em; margin-right: 8em }
  #films td, #films th { border-bottom: thin solid grey; vertical-align: top; width: 36em; padding-left: 6px; padding-right: 6px; padding-top: 3px; padding-bottom: 3px }
  #films tr td:nth-of-type(1) { width: 24em}
  #films tr td.release_dates { width: 6em}
  #films tr td.wd_id { width: 6em}
  #films tr th { text-align: left }
</style>
% }
<div id="container">
% use autobox::Lookup;
<table id="films">
  <tr><th>id</th><th>label</th><th>description</th><th>title</th></tr>
% for my $d ($entities->@*) {
<tr>
  <td>
    <%= $d->get("id") %>
  </td>
  <td>
    <%= [ map { $d->get("labels.$_.value") } qw/en it de fr es/]->[0] %>
  </td>
  <td>
    <%= [ map { $d->get("descriptions.$_.value") } qw/en it de fr es/]->[0] %>
  </td>
  <td>
      <%= join " / ", ($d->get("claims.P1476.[].mainsnak.datavalue.value.text") || [])->@* %>
  </td>
</tr>
% }
</table>
</div>
@@ data/detail.html.ep
% layout 'default';
%= include 'menu';
<style>
  #container { margin-left: 8em; margin-right: 8em }
  td, th { border-bottom: thin solid grey; vertical-align: top; padding-left: 6px; padding-right: 6px; padding-top: 3px; padding-bottom: 3px }
</style>
<div id="container">
  <h2><%= $info->{P1476}->{values}->[0] %></h2>
<table>
% for my $f ($fields->@*) {
<tr>
  % if ($info->{$f}) {
  <td><%= $info->{$f}->{description} %></td>
  <td><%= $f %></td>
  <td><%= join ", ", ($info->{$f}->{values} || [])->@* %></td>
  % }
</tr>
% }
</table>
</div>
@@ ikea.html.ep
Numero d'Ordine
145 726 5698

package Melies::Plugin::Wikidata;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Util qw/trim dumper/;
use Mojo::UserAgent;
use autobox::Lookup;

has "ua" => sub { Mojo::UserAgent->new->max_redirects(5) };
has "app";

sub get_entities_p {
    my $self = shift;
    my @ids = ref $_[0] eq "ARRAY" ? shift->@* : @_;;
    my @results;
    Mojo::Promise->all_settled(map { $self->ua->get_p("https://www.wikidata.org/wiki/Special:EntityData/$_.json") } @ids)
	  ->then(sub {
		     return map { $_->{value}->[0]->res->json } @_;
		 })
}

sub search_ids_p {
    my $self = shift;
    my $search_term = shift;
    my $opts = shift || {};

    $self->ua->get_p( 'https://www.wikidata.org/w/api.php' => form =>
		      { action  => 'wbsearchentities', limit => 50, search => $search_term, format  => 'json', language => 'en', } )
	->then(sub {
		   my $tx = shift;
		   my @ids = map { $_->get("id") } $tx->res->json->{search}->@*;
		   return \@ids;
	       });
}

sub get_properties_p {
    my $self = shift;
    my $id = shift;
    my $props = shift;

    $self->ua->get_p("https://www.wikidata.org/wiki/" . $id)
	->then(sub {
		   my $tx = shift;
		   my $dom = $tx->res->dom;
		   $dom->find(".wikibase-statementview-references-container")->each(sub { $_->remove });

		   $dom->find(".wikibase-statementgroupview")
		       ->map(sub {
				 return {
					 id => $_->attr("id"),
					 description => ($_->at(".wikibase-statementgroupview-property-label")->all_text =~ s/^instance of$/is a/r),
					 values => $_->find(".wikibase-statementview-mainsnak")->map(sub { trim $_->all_text })
				 }
			     })
		   });
}


sub register {
    my ($self, $app, $conf) = @_;

    $self->app($app);

    $app->helper(search_wikidata_p => sub {
		     my ($c, $search_term, $categories) = @_;
		     $self->search_ids_p($search_term)
			 ->then(sub {
				    return () unless $_[0]->@*;
				    $self->get_entities_p($_[0])
				})
			 ->then(sub {
				    my @entities =
					grep { _intersect($_->get("claims.P31.[].mainsnak.datavalue.value.id"), $categories)->@* }
					map { $_->get("entities")->values->[0] }
					@_;
				})
		 });

    $app->helper(get_wikidata_p => sub {
		     my $c = shift;
		     $self->get_properties_p(@_);
		 });
}

sub _intersect {
    my $aref_a = shift;
    my $aref_b = { map { $_ => 1 } shift()->@* };
    [ grep { $aref_b->{$_} } $aref_a->@* ];
}

1;

use strict;
use warnings;
use Test::More;
use Plack::Test;
use Plack::Builder;
use HTTP::Request::Common;

use Plack::App::RDF::Files;

my $app = Plack::App::RDF::Files->new(
    base_dir => './t/data',
    base_uri => 'http://example.org/'
);

test_psgi $app, sub {
    my $cb = shift;

    my $res = $cb->(GET "/xxx");
    is $res->code, 404, "not found";

    $res = $cb->(GET "/alice");
    is $res->code, 200;
    is $res->content,
        "<http://example.org/alice> <http://xmlns.com/foaf/0.1/knows> <http://example.org/bob> .\n",
        "simple graph";

    $res = $cb->(GET "/foo");
    is $res->code, 200;
    is $res->content,
        "<http://example.org/foo> a <http://www.w3.org/2000/01/rdf-schema#Resource> .\n",
        "empty graph";

    $res = $cb->(GET "/foo/bar");
    is $res->code, 200;
    is $res->content,
        "<http://example.org/foo/bar> <http://www.w3.org/2000/01/rdf-schema#type> <http://example.org/Thing> .\n";
};

# test env
#my $stack = builder {
#    sub {
#        # TODO: test $env after processing
#    };
#    $app;
#};
#$stack->call(...)

=head1
$app = Plack::App::RDF::Files->new( base_dir => 't' );

test_psgi $app, sub {
	my $cb  = shift;

	my $res = $cb->(GET "/rdf1", Accept => 'text/turtle'); 
	is $res->code, '200', '200 OK';
    is $res->header('Content-Type'), 'text/turtle', 'text/turtle';

    foreach my $missing ("/rdf0", "/", "../t/rdf1") {
    	my $res = $cb->(GET $missing, Accept => 'text/turtle'); 
	    is $res->code, '404', '404 not ok';
    }
};

$app = Plack::App::RDF::Files->new( base_dir => 't', include_index => 1 );

test_psgi $app, sub {
	my $cb  = shift;
	my $res = $cb->(GET "/", Accept => 'text/turtle'); 
	is $res->code, '200', '200 OK';
};
=cut

done_testing;

use strict;
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
    is $res->code, 404, "unknown URI";

    $res = $cb->(GET "/empty");
    is $res->code, 200;
    is $res->content,
        "<http://example.org/empty> a <http://www.w3.org/2000/01/rdf-schema#Resource> .\n",
        "empty graph";

    $res = $cb->(GET "/alice");
    is $res->code, 200;
    is $res->content,
        "<http://example.org/alice> <http://xmlns.com/foaf/0.1/knows> <http://example.org/bob> .\n",
        "simple graph";
};

# test env
#my $stack = builder {
#    sub {
#        # TODO: test $env after processing
#    };
#    $app;
#};
#$stack->call(...)

done_testing;

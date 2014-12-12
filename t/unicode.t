use strict;
use warnings;
use Test::More;
use Plack::Test;
use HTTP::Request::Common;

use Plack::App::RDF::Files;

my $app = Plack::App::RDF::Files->new( base_dir => 't/data' );

test_psgi $app, sub {
    my ($cb, $res) = @_;

    $res = $cb->(GET "/unicode");

    foreach my $type (qw(application/rdf+xml application/x-rdf+json)) {
        $res = $cb->(GET "/unicode", Accept => $type);
        like $res->content, qr/1:ö/m, "ö";
        like $res->content, qr/2:o\x{cc}\x{88}/m, "o + combining diaeresis (UTF-8)";
        like $res->content, qr/3:\x{c3}\x{b6} o\x{cc}\x{88}/m, "ö (UTF-8)";
    }
};

done_testing;

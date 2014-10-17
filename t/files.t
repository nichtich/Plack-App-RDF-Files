use strict;
use warnings;
use Test::More;
use HTTP::Message::PSGI;
use HTTP::Request;

use Plack::App::RDF::Files;

test_files(
    { base_dir => './t/data', base_uri => 'http://example.org/', include_index => 1 },
    [ GET => 'http://example.org/' ],
   't/data' => { },
);

test_files(
    { base_dir => './t/data', base_uri => 'http://example.org/' },
    [ GET => 'http://example.org/' ],
   undef
);

test_files(
    { base_dir => './t/data', base_uri => 'http://example.org/' },
    [ GET => '/alice' ],
   't/data/alice' => { },
);

test_files(
    { base_dir => './t/data', base_uri => 'http://example.org/' },
    '/alice',
   't/data/alice' => { },
);

test_files(
    { base_dir => './t/data' },
    [ GET => 'http://example.com/alice' ],
   't/data/alice' => { },
);


sub test_files {
    my $app = Plack::App::RDF::Files->new( %{(shift)} )->prepare_app;
    my $req = shift;
    my @result = @_;

    my $check = sub {
        my ($dir, $files) = @_;

        #use Data::Dumper;
        #say Dumper( [ $dir, $files ] );

        is( $dir, $result[0], defined $dir ? 'found' : 'not found' ); 

        # TODO: check files
    };

    if (ref $req) {
        $req = HTTP::Request->new( @$req  );
        my $env = req_to_psgi( $req );
        $check->( $app->files( $env ) );
        my $uri = $req->uri;
        if ($uri !~ /^http:/) {
            $uri = $app->base_uri . substr($uri,1);
        }
        is( $env->{'rdf.uri'}, $uri, $uri );
    } else {
        my $path = $req;
        $check->( $app->files( $path ) );
    }
}

done_testing;

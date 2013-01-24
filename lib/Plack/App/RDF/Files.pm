package Plack::App::RDF::Files;
#ABSTRACT: Combine and serve RDF from static files
use strict;
use warnings;
use v5.10.1;

use parent 'Plack::Component';
use Plack::Util::Accessor qw(base_dir base_uri file_types listing_property);

use Plack::Request;
use RDF::Trine qw(statement iri);
use RDF::Trine::Model;
use RDF::Trine::Parser;
use RDF::Trine::Iterator::Graph;
use RDF::Trine::Serializer;
use File::Spec::Functions qw(catfile catdir);
use Scalar::Util;
use URI;

our %FORMATS = (
    ttl => 'Turtle',
    nt  => 'NTriples',
    n3  => 'Notation3',
    json => 'RDFJSON',
    rdfxml => 'RDFXML'
);

sub prepare_app {
    my $self = shift;
    return if $self->{prepared};
    
    die "Missing base_dir" 
        unless -d ($self->base_dir // '/dev/null');

    $self->base_uri( URI->new( $self->base_uri ) ) 
        if $self->base_uri;

    my $types = join '|', @{ $self->file_types // [qw(rdfxml nt ttl)] };
    $self->file_types( qr/^($types)/ );

    $self->listing_property( 'http://www.w3.org/2000/01/rdf-schema#seeAlso' )
        unless defined $self->listing_property;
    if ( $self->listing_property ) {
        $self->listing_property( iri( $self->listing_property ) );
    }

    $self->{prepared} = 1;
}

sub call {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    return [ 405, [ 'Content-type' => 'text/plain' ], [ 'Method not allowed' ] ]
        unless (($req->method eq 'GET') || ($req->method eq 'HEAD'));

    my $base = $self->base_uri // $req->base;
    my $path = substr($req->path,1);

    # TODO: configure allowed characters
    return [ 404, [ 'Content-type' => 'text/plain' ], [ "Not found" ] ]
        unless $path =~ /^[a-z0-9:\._@-]*$/i and $path !~ /\.\.\//;

    my $uri = URI->new( $base . $path );
    my $dir = catdir( $self->base_dir, $path );

    $env->{'rdflow.uri'} = $uri; # TODO: document this

    return [ 404, [ 'Content-type' => 'text/plain' ], [ "Not found: $uri" ] ]
        unless -d $dir;

    return [ 403, [ 'Content-type' => 'text/plain' ], [ "Not accessible: $uri" ] ]
        unless -r $dir and opendir(my $dirhandle, $dir); 
 
    # TODO: calculate etag (for caching and for http HEAD method) and cache $model (?)


    # combine RDF files
    my $model = RDF::Trine::Model->new;

    my @files = grep { 
        $_ =~ /\.(\w+)$/ && $1 =~ $self->file_types;
    } readdir $dirhandle;
    closedir $dirhandle;

    foreach my $file (@files) {
        my $parser = RDF::Trine::Parser->guess_parser_by_filename( $file );
        $file = catfile( $dir, $file );

        # TODO: this may fail
        $parser->parse_file_into_model( $uri, $file, $model );
    }

    my $iter = $model->as_stream;


    # add listing on base URI
    if ( $path eq '' and $self->listing_property ) {
        my $subject   = iri( $uri );
        my $predicate = $self->listing_property;
        my @stms;
        opendir(my $dirhandle, $dir);
        foreach my $p (readdir $dirhandle) {
            next unless -d catdir( $dir, $p ) and $p !~ /^\.\.?$/;
            push @stms, statement(
                $subject, 
                $predicate, 
                RDF::Trine::Node::Resource->new( "$uri$p" )
            );
        }
        closedir $dirhandle;

        my $i2 = RDF::Trine::Iterator::Graph->new( \@stms );
        $iter = $iter->concat( $i2 );
    }


    # add axiomatic triple to empty graphs
    if ($iter->finished) {
        $iter = RDF::Trine::Iterator::Graph->new( [ statement( 
            iri($uri),
            iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#'), 
            iri('http://www.w3.org/2000/01/rdf-schema#Resource')
        ) ] );
    }

    # TODO: do not serialize at all on request
    # $env->{'rdflow.data'} = $iter;

    # negotiate and serialize
    my ($ser, @headers) = $self->negotiate( $env, $uri );
    if (!$ser) {
        $ser = RDF::Trine::Serializer->new( 'NTriples', base_uri => $uri );
        @headers = ('Content-type' => 'text/plain');
    }

    if ( $env->{'psgi.streaming'} ) {
        return sub {
            my $responder = shift;
            # TODO: use IO::Handle::Iterator to serialize as last as possible
            my $rdf = $ser->serialize_iterator_to_string( $iter );
            $responder->( [ 200, [ @headers ], [ $rdf ] ] );
        };
    } else {
        my $rdf = $ser->serialize_iterator_to_string( $iter );
        return [200, [ @headers ], [ $rdf ] ];
    }
}

=method negotiate( $env, $base_uri )

Selects an RDF serializer based on the PSGI environment variable
C<negotiate.format> (see L<Plack::Middleware::Negotiate>) or the C<negotiate>
method of L<RDF::Trine::Serializer>. Returns a L<RDF::Trine::Serializer> (or
C<undef> on error) and a (possibly empty) list of HTTP response headers.

=cut

sub negotiate {
    my ($self, $env, $base_uri) = @_;

    my %options = (
        base => $base_uri,
        # namespaces => $self->_namespace_hashref # TODO: pretty
    );

    if ( $env->{'negotiate.format'} ) {

        # TODO: document this
        my $format = $FORMATS{$env->{'negotiate.format'}} // $env->{'negotiate.format'};

        my $ser = eval { # TODO: catch RDF::Trine::Error::SerializationError and log
            RDF::Trine::Serializer->new( $format, %options ) 
        }; # maybe rdflow.error ?
        #  push @headers,  Vary => 'Accept'; ??

        return ($ser);
    } else {
        my ($ctype, $ser) = RDF::Trine::Serializer->negotiate(
            request_headers => Plack::Request->new($env)->headers,
        );
        my @headers = ( 'Content-type' => $ctype, Vary => 'Accept' );
        return ($ser, @headers);
    }
}

1;

=head1 DESCRIPTION

This Plack application serves RDF from static files instead of using a triple
store. In short, each RDF resource to be served corresponds to a directory in
the file system. 

=head2 EXAMPLE

Let's assume you have a base directory C</var/rdf/> with some subdirectories
C<foo>, C<bar>, and C<doz>. Given a base URI, such as <http://example.org/>, an
instance of Plack::App::RDF::Files will serve RDF data for the following URIs:

    http://example.org/
    http://example.org/foo
    http://example.org/bar
    http://example.org/doz

The actual RDF data is collected and combined from RDF files (C<*.nt>,
C<*.ttl>, C<*.rdfxml>...) in each directory. There is no need to set up a
triple store, just create and modify directories and RDF files.

=head1 CONFIGURATION

=over 4

=item base_dir

Mandatory base directory that all resource directories are located in.

=item base_uri

The base URI of all resources. 

=item file_types

An array of RDF file types (extensions) to look for. Set to
C<['rdfxml','nt','ttl']> by default.

=item listing_property

RDF property to use for listing all resources connected to the base URI.  Set
to C<rdfs:seeAlso> by default. Can be disabled by setting a false value.

=back

=head1 LIMITATIONS

B<This module is an early developer release. Be warned!>

All resource URIs to be served must have a common URI prefix (such as
C<http://example.org/> above) and a local part that may be restricted to a
limited set of characters. For instance the character sequence C<../> is 
not allowed.

=head1 NOTES

If an existing resource does not contain triples, the axiomatic triple
C<< ?uri rdf:type rdfs:Resource >> is returned.

To update the files, add a middleware that catches 404 and 202 responses.

=head1 TODO

VoID descriptions could be added, possibly with L<RDF::Generator::Void>.

=head1 SEE ALSO

See L<RDF::LinkedData> for a different module to serve RDF as linked data.
See also L<RDF::Flow>.

=cut

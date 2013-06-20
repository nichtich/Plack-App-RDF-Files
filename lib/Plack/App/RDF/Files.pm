package Plack::App::RDF::Files;
#ABSTRACT: Serve RDF data from static files

use v5.14;

use parent 'Plack::Component';
use Plack::Util::Accessor qw(base_dir base_uri file_types path_map
    include_index index_property namespaces);

use Plack::Request;
use RDF::Trine qw(statement iri);
use RDF::Trine::Model;
use RDF::Trine::Parser;
use RDF::Trine::Iterator::Graph;
use RDF::Trine::Serializer;
use File::Spec::Functions qw(catfile catdir);
use Scalar::Util qw(reftype);
use URI;

our %FORMATS = (
    ttl     => 'Turtle',
    nt      => 'NTriples',
    n3      => 'Notation3',
    json    => 'RDFJSON',
    rdfxml  => 'RDFXML'
    # TODO: jsonld
);

sub prepare_app {
    my $self = shift;
    return if $self->{prepared};

    die "missing base_dir" unless $self->base_dir and -d $self->base_dir;

    $self->base_uri( URI->new( $self->base_uri ) )
        if $self->base_uri;

    my $types = join '|', @{ $self->file_types // [qw(rdfxml nt ttl)] };
    $self->file_types( qr/^($types)/ );

    if ( $self->include_index ) {
        $self->index_property( 'http://www.w3.org/2000/01/rdf-schema#seeAlso' )
            unless defined $self->index_property;
        $self->index_property( iri( $self->index_property ) )
            if $self->index_property;
    }

    $self->path_map( sub { shift } ) unless $self->path_map;

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
        if $path !~ /^[a-z0-9:\._@-]*$/i or $path =~ /\.\.\// or
           ( $path eq '' and !$self->include_index );

    my $uri = URI->new( $base . $path );

    $env->{'rdf.uri'} = $uri; # TODO: document this

    my $dir = catdir( $self->base_dir, $self->path_map->($path) );

    return [ 404, [ 'Content-type' => 'text/plain' ], [ "Not found: $uri" ] ]
        unless -d $dir;

    return [ 403, [ 'Content-type' => 'text/plain' ], [ "Not accessible: $uri" ] ]
        unless -r $dir and opendir(my $dirhandle, $dir);

    # TODO: calculate etag (for caching and for http HEAD method) and cache $model (?)


    # combine RDF files
    my $model = RDF::Trine::Model->new;

    my %rdffiles = ();

    my @files = grep {
        $_ =~ /\.(\w+)$/ && $1 =~ $self->file_types;
    } readdir $dirhandle;
    closedir $dirhandle;

    my $size = 0;
    my $lastmtime = 0;
    foreach my $file (@files) {
        my $parser = RDF::Trine::Parser->guess_parser_by_filename( $file );
        my $absfile = catfile($dir,$file);

        my $mtime =(stat($absfile))[9];
        my $about = $rdffiles{$file} = { mtime => $mtime };
        $lastmtime = $mtime if $mtime > $lastmtime;

        eval {
            $parser->parse_file_into_model( $uri, $absfile, $model );
        };
        if ($@) {
            $about->{error} = $@;
        } else {
            $about->{size} = $model->size - $size;
            $size = $model->size;
        }
    }
    $env->{'rdf.files'} = \%rdffiles;
    $env->{'rdf.files.mtime'} = $lastmtime;


    my $iter = $model->as_stream;

    # add listing on base URI
    if ( $path eq '' and $self->index_property ) {
        my $subject   = iri( $uri );
        my $predicate = $self->index_property;
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
            iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
            iri('http://www.w3.org/2000/01/rdf-schema#Resource')
        ) ] );
    }

    # TODO: do not serialize at all on request
    # $env->{'rdflow.data'} = $iter;
    $env->{'rdf.iterator'} = $iter;

    # TODO: HTTP HEAD method

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
            use Encode; # must be bytes
            $rdf = encode("UTF8",$rdf);
            $responder->( [ 200, [ @headers ], [ $rdf ] ] );
        };
    } else {
        my $rdf = $ser->serialize_iterator_to_string( $iter );
        return [200, [ @headers ], [ $rdf ] ];
    }
}

=method negotiate( $env )

Selects an RDF serializer based on the PSGI environment variable
C<negotiate.format> (see L<Plack::Middleware::Negotiate>) or the C<negotiate>
method of L<RDF::Trine::Serializer>. Returns first a L<RDF::Trine::Serializer>
on success or C<undef> on error) and second a (possibly empty) list of HTTP
response headers.

=cut

sub negotiate {
    my ($self, $env) = @_;

    my %options = (
        base       => $env->{'rdflow.uri'},
        namespaces => ( $self->namespaces // { } )
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

This L<Plack> application serves RDF from static files. In short, each RDF
resource to be served corresponds to a directory in the file system, located in
a common based directory C<base_dir>. All RDF resources must share a common
base URI, which is either taken from the L<PSGI> request or configured with
C<base_uri>.

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

=item path_map

Optional code reference that maps a local part of an URI to a relative
directory. Set to the identity mapping by default.

=item file_types

An array of RDF file types (extensions) to look for. Set to
C<['rdfxml','nt','ttl']> by default.

=item include_index

By default a HTTP 404 error is returned if one tries to access the base
directory. Enable this option to also serve RDF data from this location.

=item index_property

RDF property to use for listing all resources connected to the base URI (if
<include_index> is enabled).  Set to C<rdfs:seeAlso> by default. Can be
disabled by setting a false value.

=back

=head1 PSGI environment variables

The following PSGI environment variables are set:

=over 4

=item rdf.uri

=item rdf.iterator

=item rdf.files

An hash of source filenames, each with the number of triples (on success)
as property C<size>, an error message as C<error> if parsing failed, and
the timestamp of last modification as C<mtime>.

=item rdf.files.mtime

Maximum value of all last modification times.

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

Use L<Plack::Middleware::Negotiate> to add content negotiation based on
an URL parameter and/or suffix.

See L<RDF::LinkedData> for a different module to serve RDF as linked data.
See also L<RDF::Flow> and L<RDF::Lazy> for processing RDF data.

See L<http://foafpress.org/> for a similar approach in PHP.

=cut

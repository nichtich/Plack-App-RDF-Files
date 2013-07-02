package Plack::App::RDF::Files;
#ABSTRACT: Serve RDF data from files

use v5.14;

use parent 'Plack::Component';
use Plack::Util::Accessor qw(
    base_dir base_uri file_types path_map
    include_index index_property namespaces
);

use Plack::Request;
use RDF::Trine qw(statement iri);
use RDF::Trine::Model;
use RDF::Trine::Parser;
use RDF::Trine::Serializer;
use RDF::Trine::Iterator::Graph;
use File::Spec::Functions qw(catfile catdir);
use URI;
use Scalar::Util qw(blessed reftype);
use Carp qw(croak);
use Digest::MD5 qw(md5_hex);
use HTTP::Date;
use List::Util qw(max);


our %FORMATS = (
    ttl     => 'Turtle',
    nt      => 'NTriples',
    n3      => 'Notation3',
    json    => 'RDFJSON',
    rdfxml  => 'RDFXML'
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

    $self;
}

=method files( $env | $req | $str )

Get a list of RDF files that will be read for a given request. The request can
be specified as L<PSGI> environment, as L<Plack::Request>, or as partial URI
that follows C<base_uri> (given as string). The requested URI is saved in field
C<rdf.uri> of the request environment.  On success returns the base directory
and a list of files, each mapped to its last modification time.  Undef is
returned if the request contained invalid characters (everything but
C<a-zA-Z0-9:.@-> and the forbidden sequence C<../>) or if the request equals ro
the base URI and C<include_index> was not enabled.

=cut

sub files {
    my $self = shift;

    my ($env, $req, $path);

    if (!reftype($_[0])) {                                      # $str
        return unless $self->base_uri and defined $_[0];
        # TODO: support full URIs via HTTP::Request
        $path = substr(shift,1);
        $env = { };
    } elsif (!blessed($_[0]) and reftype($_[0]) eq 'HASH') {    # $env
        $env  = shift;
        $req  = Plack::Request->new($env);
        $path = substr($req->path,1);
    } elsif (blessed($_[0]) and $_[0]->isa('Plack::Request')) { # $req
        $req  = shift;
        $env  = $req->env;
        $path = substr($req->path,1);
    } else {
        croak "expected PSGI request or string";
    }

    return if $path !~ /^[a-z0-9:\._@\/-]*$/i or $path =~ /\.\.\/|^\//;

    $env->{'rdf.uri'} = URI->new( ($self->base_uri // $req->base) . $path );

    return if $path eq '' and !$self->include_index;

    my $dir = catdir( $self->base_dir, $self->path_map->($path) );

    return unless -d $dir;
    return ($dir) unless -r $dir and opendir(my $dh, $dir);

    my $files = { };
    while( readdir $dh ) {
        next if $_ !~ /\.(\w+)$/ || $1 !~ $self->file_types;
        my $full = catfile( $dir, $_ );
        $files->{$_} = {
            full  => $full,
            size  => (stat($full))[7],
            mtime => (stat($full))[9],
        }
    }
    closedir $dh;

    return ( $dir => $files );
}


sub call {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    return [ 405, [ 'Content-type' => 'text/plain' ], [ 'Method not allowed' ] ]
        unless (($req->method eq 'GET') || ($req->method eq 'HEAD'));

    my ($dir, $files) = $self->files( $req );

    if (!$files) {
        my $status  = 404;
        my $message = $req->env->{'rdf.uri'}
                    ? "Not found: " . $req->env->{'rdf.uri'} : "Not found";

        if ($dir and -d $dir) {
            $status = 404;
            $message =~ s/found/accesible/;
        }

        return [ $status, [ 'Content-type' => 'text/plain' ], [ $message ] ];
    }

    my $uri = $env->{'rdf.uri'};
    my @headers;

    # TODO: show example with Plack::Middleware::ConditionalGET

    my $md5 = md5_hex( map { values %{$_} } values %$files );
    push @headers, ETag => "W/\"$md5\"";

    my $lastmod = max map { $_->{mtime} } values %$files;
    push @headers, 'Last-Modified' => HTTP::Date::time2str($lastmod) if $lastmod;

    # TODO: HEAD method

    # parse RDF
    my $model = RDF::Trine::Model->new;
    my $triples = 0;
    foreach (keys %$files) { # TODO: parse sorted by modifcation time?
        my $file = $files->{$_};

        my $parser = RDF::Trine::Parser->guess_parser_by_filename( $file->{full} );
        eval {
            $parser->parse_file_into_model( $uri, $file->{full}, $model );
        };
        if ($@) {
            $file->{error} = $@;
        } else {
            $file->{triples} = $model->size - $triples;
            $triples = $model->size;
        }
    }
    $env->{'rdf.files'} = $files;

    my $iter = $model->as_stream;

    # add listing on base URI
    if ( $self->index_property and "$uri" eq ($self->base_uri // $req->base) ) {
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

    # TODO: HTTP HEAD method

    # negotiate and serialize
    my ($ser, @h) = $self->negotiate( $env, $uri );
    push @headers, @h;

    if (!$ser) {
        $ser = RDF::Trine::Serializer->new( 'NTriples', base_uri => $uri );
        @headers = ('Content-type' => 'text/plain');
    }

    if ( $env->{'psgi.streaming'} ) {
        $env->{'rdf.iterator'} = $iter;
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

This internal methods selects an RDF serializer based on the PSGI environment 
variable C<negotiate.format> (see L<Plack::Middleware::Negotiate>) or the 
C<negotiate> method of L<RDF::Trine::Serializer>. Returns first a 
L<RDF::Trine::Serializer> on success or C<undef> on error) and second a 
(possibly empty) list of HTTP response headers.

=cut

sub negotiate {
    my ($self, $env) = @_;

    if ( $env->{'negotiate.format'} ) {
		# TODO: catch RDF::Trine::Error::SerializationError and log
        my $ser = eval {
            RDF::Trine::Serializer->new( 
                $FORMATS{$env->{'negotiate.format'}} // $env->{'negotiate.format'},
                base       => $env->{'rdflow.uri'},
                namespaces => ( $self->namespaces // { } ),
            )
        };
        # TODO: push @headers, Vary => 'Accept'; ?
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

=head1 SYNOPSIS

    my $app = Plack::App::RDF::Files->new(
        base_dir => '/var/rdf/
    );

    # Requests URI            =>  RDF files
    # http://example.org/     =>  /path/to/rdf/*.(nt|ttl|rdfxml)
    # http://example.org/foo  =>  /path/to/rdf/foo/*.(nt|ttl|rdfxml)
    # http://example.org/x/y  =>  /path/to/rdf/x/y/*.(nt|ttl|rdfxml)

=head1 DESCRIPTION

This L<PSGI> application serves RDF from files. Each accessible RDF resource
corresponds to a (sub)directory, located in a common based directory. All RDF
files in a directory are merged and returned as RDF graph.

=head1 CONFIGURATION

=over 4

=item base_dir

Mandatory base directory that all resource directories are located in.

=item base_uri

The base URI of all resources. If no base URI has been specified, the
base URI is taken from the PSGI request.

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

=item path_map

Optional code reference that maps a local part of an URI to a relative
directory. Set to the identity mapping by default.

=item namespaces

Optional namespaces for serialization, passed to L<RDF::Trine::Serializer>.

=back

=head1 PSGI environment variables

The following PSGI environment variables are relevant:

=over 4

=item rdf.uri

The requested URI

=item rdf.iterator

The L<RDF::Trine::Iterator> that will be used for serializing, if
C<psgi.streaming> is set. One can use this variable to catch the RDF
data in another post-processing middleware.

=item rdf.files

An hash of source filenames, each with the number of triples (on success)
as property C<size>, an error message as C<error> if parsing failed, and
the timestamp of last modification as C<mtime>. C<size> and C<error> may
not be given before parsing, if C<rdf.iterator> is set.

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

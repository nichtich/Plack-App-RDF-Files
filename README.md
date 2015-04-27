# NAME

Plack::App::RDF::Files - serve RDF data from files

# STATUS

[![Build Status](https://travis-ci.org/nichtich/Plack-App-RDF-Files.png)](https://travis-ci.org/nichtich/Plack-App-RDF-Files)
[![Coverage Status](https://coveralls.io/repos/nichtich/Plack-App-RDF-Files/badge.png)](https://coveralls.io/r/nichtich/Plack-App-RDF-Files)
[![Kwalitee Score](http://cpants.cpanauthors.org/dist/Plack-App-RDF-Files.png)](http://cpants.cpanauthors.org/dist/Plack-App-RDF-Files)

# SYNOPSIS

Create and run a Linked Open Data server in one line:

    plackup -e 'use Plack::App::RDF::Files "app"; app(base_dir=>"/path/to/rdf")'

In more detail, create a file `app.psgi`:

    use Plack::App::RDF::Files;
    Plack::App::RDF::Files->new(
        base_dir => '/path/to/rdf/',       # mandatory
        base_uri => 'http://example.org/'  # optional
    )->to_app;

Run it as web application by calling `plackup`. Request URLs are then mapped
to URIs and directories to return data from RDF files as following:

    http://localhost:5000/foo  =>  http://example.org/foo
                                         /path/to/rdf/foo/
                                         /path/to/rdf/foo/*.(nt|ttl|rdfxml)
    http://localhost:5000/x/y  =>  http://example.org/x/y
                                         /path/to/rdf/x/y/
                                         /path/to/rdf/x/y/*.(nt|ttl|rdfxml)

In short, each subdirectory corresponds to an RDF resource.

# DESCRIPTION

This [PSGI](https://metacpan.org/pod/PSGI) application serves RDF from files. Each accessible RDF resource
corresponds to a (sub)directory, located in a common based directory. All RDF
files in a directory are merged and returned as RDF graph. If no RDF data was
found in an existing subdirectory, an axiomatic triple is returned:

    $REQUEST_URI <a <http://www.w3.org/2000/01/rdf-schema#Resource> .

Requesting the base directory, however will result in a HTTP 404 error unless
option `index_property` is enabled.

HTTP HEAD and conditional GET requests are supported by ETag and
Last-Modified-Headers (see [Plack::Middleware::ConditionalGET](https://metacpan.org/pod/Plack::Middleware::ConditionalGET)).

# CONFIGURATION

- base\_dir

    Mandatory base directory that all resource directories are located in.

- base\_uri

    The base URI of all resources. If no base URI has been specified, the
    base URI is taken from the PSGI request.

- file\_types

    An array of RDF file types, given as extensions to look for. Set to
    `['rdfxml','nt','ttl']` by default.

- index\_property

    By default a HTTP 404 error is returned if one tries to access the base
    directory. Enable this option by setting it to 1 or to an URI, to also serve
    RDF data from the base directory.  By default
    `http://www.w3.org/2000/01/rdf-schema#seeAlso` is used as index property, if
    enabled.

- path\_map

    Optional code reference that maps a local part of an URI to a relative
    directory. Set to the identity mapping by default.

- namespaces

    Optional namespaces for serialization, passed to [RDF::Trine::Serializer](https://metacpan.org/pod/RDF::Trine::Serializer).

- normalize

    Optional Unicode Normalization form (NFD, NFKC, NFC, NFKC). Requires
    [Unicode::Normalize](https://metacpan.org/pod/Unicode::Normalize).

# METHODS

## call( $env )

Core method of the PSGI application.

The following PSGI environment variables are read and/or set by the
application.

- rdf.uri

    The requested URI as string or [URI](https://metacpan.org/pod/URI) object.

- rdf.iterator

    The [RDF::Trine::Iterator](https://metacpan.org/pod/RDF::Trine::Iterator) that will be used for serializing, if
    `psgi.streaming` is set. One can use this variable to catch the RDF
    data in another post-processing middleware.

- rdf.files

    An hash of source filenames, each with the number of triples (on success)
    as property `size`, an error message as `error` if parsing failed, and
    the timestamp of last modification as `mtime`. `size` and `error` may
    not be given before parsing, if `rdf.iterator` is set.

- negotiate.format

    RDF serialization format (See [Plack::Middleware::Negotiate](https://metacpan.org/pod/Plack::Middleware::Negotiate)). Supported
    values are `ttl`, `nt`, `n3`, `json`, and `rdfxml`.

If an existing resource does not contain triples, the axiomatic triple
`$uri rdf:type rdfs:Resource` is returned.

## files( $env )

Get a list of RDF files (as hash reference) that will be read for a given
request, given as [PSGI](https://metacpan.org/pod/PSGI) environment.

The requested URI is saved in field `rdf.uri` of the request environment.  On
success returns the base directory and a list of files, each mapped to its last
modification time.  Undef is returned if the request contained invalid
characters (everything but `a-zA-Z0-9:.@/-` and the forbidden sequence `../`
or a sequence starting with `/`), or if called with the base URI and
`index_property` not enabled.

## headers( $files ) 

Get a response headers object (as provided by [Plack::Util](https://metacpan.org/pod/Plack::Util)::headers) with
ETag and Last-Modified from a list of RDF files given as returned by the files
method.

# FUNCTIONS

## app( %options )

This shortcut for `Plack::App::RDF::Files->new` can be exported on request
to simplify one-liners.

# SEE ALSO

Use [Plack::Middleware::Negotiate](https://metacpan.org/pod/Plack::Middleware::Negotiate) to add content negotiation based on
an URL parameter and/or suffix.

See [RDF::LinkedData](https://metacpan.org/pod/RDF::LinkedData) for a different module to serve RDF as linked data.
See also [RDF::Flow](https://metacpan.org/pod/RDF::Flow) and [RDF::Lazy](https://metacpan.org/pod/RDF::Lazy) for processing RDF data.

See [http://foafpress.org/](http://foafpress.org/) for a similar approach in PHP.

# COPYRIGHT AND LICENSE

Copyright Jakob Voss, 2014-

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

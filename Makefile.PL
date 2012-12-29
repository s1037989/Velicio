use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Velicio',
    AUTHOR              => q{Stefan Adams <stefan@cogentinnovators.com>},
    VERSION_FROM        => 'lib/Velicio.pm',
    ABSTRACT_FROM       => 'lib/Velicio.pm',
    EXE_FILES           => [ 'sbin/velicio' ],
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More'                     => 0,
        'Getopt::Long'                   => 0,
        'File::Path'                     => 0,
        'Scalar::Util'                   => 0,
        'Data::Serializer'               => 0,
        'Sys::Hostname'                  => 0,
        'Mojo::Util'                     => 0,
        'Mojo::IOLoop'                   => 0,
        'Mojo::UserAgent'                => 0,
        'Data::Dumper'                   => 0,
        'Storable'                       => 0,
        'Data::Serializer::Storable'     => 0,
        'Compress::Zlib'                 => 0,
        'Digest'                         => 0,
        'CPAN'                           => 0,
        'Data::Serializer::Data::Dumper' => 0,
        'App::Daemon'                    => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Velicio-*' },
);

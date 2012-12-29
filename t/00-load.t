#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Velicio' ) || print "Bail out!\n";
}

diag( "Testing Velicio $Velicio::VERSION, Perl $], $^X" );

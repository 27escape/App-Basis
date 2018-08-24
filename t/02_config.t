#!/usr/bin/perl -w

=head1 NAME

config.t

=head1 DESCRIPTION

test App::Basis::Config

=head1 AUTHOR

kevin mulholland, moodfarm@cpan.org

=cut

use v5.10 ;
use strict ;
use warnings ;

use Test::More tests => 27 ;
use Path::Tiny ;

BEGIN { use_ok('App::Basis::Config') ; }

my @cleanup ;

# write out some config, then read it back and check it
# YAML should have blank line at the end
my $config_str = <<EOF;
name: fred
block:
  bill:
    item: one
  fred:
    misplelted:
      item: two
      another: three
last: item

EOF

my $config_file = "/tmp/$$.test" ;
push @cleanup, $config_file ;
path($config_file)->spew($config_str) ;

# if the config is not processed properly, we will end the test with a die
my $cfg = App::Basis::Config->new( filename => $config_file, die_on_error => 1 ) ;
isa_ok( $cfg, 'App::Basis::Config' ) ;
my $data = $cfg->raw ;

# test that the data was read in OK
is( $data->{name},                  'fred', 'name field' ) ;
is( $data->{block}->{bill}->{item}, 'one',  'deep nested field' ) ;
is( $data->{last},                  'item', 'item field' ) ;

# now test that the path based access works
my $name = $cfg->get('name') ;
is( $cfg->get('name'),             'fred', 'get name field' ) ;
is( $cfg->get('/block/bill/item'), 'one',  'get deep nested field' ) ;
my $v = $cfg->get('/block/fred2/misplelted') ;
ok( !defined $v, "Missing item not iterpreted" ) ;
is( $cfg->get('last'), 'item', 'get item field' ) ;

# now test setting
$cfg->set( 'test1', 123 ) ;
$data = $cfg->raw ;
is( $cfg->get('test1'), 123, 'set basic' ) ;
$cfg->set( 'test2/test3/test4', 124 ) ;
is( $cfg->get('test2/test3/test4'), 124, 'set deep nested' ) ;

# test path sepator variants
is( $cfg->get('test2:test3:test4.') , 124, 'allow period path separators' ) ;
is( $cfg->get('test2.test3.test4.') , 124, 'allow period path separators' ) ;

# test saving
my $new_file = "$config_file.new" ;
push @cleanup, $new_file ;
my $status = $cfg->store($new_file) ;
is( $status, 1, 'store' ) ;

# was it saved correctly
my $new = App::Basis::Config->new( filename => $new_file, nostore => 1 ) ;
is_deeply( $cfg->raw, $new->raw, 'Save and reload' ) ;

# make sure something has changed, otherwise there will be no store
$new->set( 'another/item', 27 ) ;

# new config should not save
$status = $new->store() ;
is( $status, 0, 'nostore' ) ;

# test creation of config from scratch
my $another_file = "$config_file.scratch" ;
push @cleanup, $another_file ;
$new = App::Basis::Config->new( filename => $another_file ) ;
$new->set( "/one/two/three", "four" ) ;
is( $new->get("/one/two/three"), "four", 'set deep path' ) ;
$new->store() ;
ok( -f $another_file, "Stored new file" ) ;

# store and retrive hashes
$data = { fred => 'one', bill => 2, barney => { value => 'three' } } ;
$new->set( "/complex", $data ) ;
is_deeply( $new->raw->{complex}, $data, 'Store complex' ) ;
my $complex = $new->get('/complex') ;
is_deeply( $complex, $data, 'retrieve complex' ) ;

# reget the file
$new = App::Basis::Config->new( filename => $another_file ) ;
my $value = $new->get("/one/two/three") ;
# setting the same value back should not have changed the store status
$new->set( "/one/two/three", $value ) ;
is( $new->changed(), 0, "Re-storing same value does not trigger store requirement" ) ;

# reget the file
$new = App::Basis::Config->new( filename => $another_file ) ;
$value = $new->get("/one/two/three") ;
# setting with an empty value is a delete
# $new->get( "/one/two/three") ;  # should have value "four"
$value = $new->get("/one/two/three") ;
$new->set("/one/two/three") ;
$value = $new->get("/one/two/three") ;
ok( !$value,              "Delete leaf" ) ;
ok( $new->changed() != 0, "Delete marks things for storage" ) ;
$new = App::Basis::Config->new( filename => $another_file ) ;
# bulk out the tree
$new->set( "/one/five", { six => 6, seven => 7 } ) ;
$new->set("/one/two") ;
$value = $new->get("/one") ;
ok( !$value->{two}, "Delete branch" ) ;
$new = App::Basis::Config->new( filename => $another_file ) ;
$new->set("/") ;
$value = $new->get("/one") ;
ok( !$value, "Tree delete" ) ;
# does store work after delete
$new = App::Basis::Config->new( filename => $another_file ) ;
# bulk out the tree
$new->set( "/one/five", { six => 6, seven => 7 } ) ;
$new->set("/one/two") ;
$new->store() ;
$new = App::Basis::Config->new( filename => $another_file ) ;
$value = $new->get("/one") ;
ok( !$value->{two}, "Store after delete" ) ;

$new->set( "/two/three", 100 ) ;
$new->set( "/two/three", 200 ) ;
$value = $new->get("/two/three") ;
is( $value, 200, "Store and store again is correct" ) ;

# and clean up the files we have created
map { unlink $_ ; } @cleanup ;

# -----------------------------------------------------------------------------
# completed all the tests

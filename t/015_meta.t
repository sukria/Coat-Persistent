use strict;
use warnings;
use Test::More tests => 7;

BEGIN { use_ok 'Coat::Persistent::Meta' }

ok( ! defined(Coat::Persistent::Meta->model('User')), 
    'model User not defined' );

ok( Coat::Persistent::Meta->table_name(User => 'users' ),
    'table_name User -> users' );
is( 'users', Coat::Persistent::Meta->table_name('User'),
    'table_name == users');

ok( defined(Coat::Persistent::Meta->model('User')), 
    'model User defined' );

ok( Coat::Persistent::Meta->primary_key(User => 'id'),
    'primary_key User -> id' );
is( 'id', Coat::Persistent::Meta->primary_key('User'),
    'primary_key == id');


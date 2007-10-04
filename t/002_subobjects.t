use strict;
use warnings;
use Test::More 'no_plan';

BEGIN { use_ok 'Coat::Persistent' }

{
    package Person;
    use Coat;
    use Coat::Persistent;

    owns_one 'Avatar';
    has_p 'name' => (isa => 'Str');
    has_p 'age' => (isa => 'Int');

    __PACKAGE__->map_to_dbi('csv', 'f_dir=./t/csv-test-database');
    
    package Avatar;
    use Coat;
    use Coat::Persistent;

    has_p 'imgpath' => (isa => 'Str');
    
    __PACKAGE__->map_to_dbi('csv', 'f_dir=./t/csv-test-database');
}

# fixture
my $dbh = Person->dbh;
$dbh->do("CREATE TABLE person (id INTEGER, avatar_id INTEGER, name CHAR(64), age INTEGER)");
$dbh->do("CREATE TABLE avatar (id INTEGER, imgpath CHAR(255))");

# TESTS 

my $a = new Avatar imgpath => '/tmp/toto.png';
$a->save;

my $p = new Person name => "Joe", age => 17;
ok( $p->save, '$p->save' );

ok( $p->avatar($a), '$p->avatar($a)' );
is( $p->avatar->id, $a->id, '$p->avatar->id == $a->id' );

is($p->avatar_id, $a->id, '$p->avatar_id == $a->id');

ok( $p->save, '$p->save');

$p = Person->find($p->id);
ok( defined $p->avatar, '$p->avatar is defined after a ->find');
is( $p->avatar->id, $a->id, '$p->avatar->id == $a->id' );


# remove the test db
$dbh->do("DROP TABLE person");
$dbh->do("DROP TABLE avatar");

use strict;
use warnings;
use Test::More 'no_plan';
use Test::Exception;

BEGIN { use_ok 'Coat::Persistent' }
{
    package Person;
    use Coat;
    use Coat::Persistent;
    has_p name => (isa => 'Str', unique => 1, syntax => '[a-zA-Z]{2}');
    has_p age  => (isa => 'Int');
}

Person->map_to_dbi('csv', 'f_dir=./t/csv-test-database');

# fixture
my $dbh = Person->dbh;
$dbh->do("CREATE TABLE person (id INTEGER, name CHAR(64), age INTEGER)");

# tests
throws_ok {
    my $p = new Person name => '213'; 
    $p->save;
} qr/Value "213" for attribute "name" is not valid/, 
'Unable to set a name only with numbers';

my $p2 = new Person name => 'jo213'; 
ok( $p2->save, 'possible to save with name with letters and numbers');

# clean
$dbh->do("drop table person");
$dbh->do("DROP TABLE dbix_sequence_state");
$dbh->do("DROP TABLE dbix_sequence_release");

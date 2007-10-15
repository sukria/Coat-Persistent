use strict;
use warnings;
use Test::More 'no_plan';
use Test::Exception;

BEGIN { use_ok 'Coat::Persistent' }
{
    package Person;
    use Coat;
    use Coat::Persistent;
    has_p name => (isa => 'Str', unique => 1);
    has_p age  => (isa => 'Int');
}

Person->map_to_dbi('csv', 'f_dir=./t/csv-test-database');

# fixture
my $dbh = Person->dbh;
$dbh->do("CREATE TABLE person (id INTEGER, name CHAR(64), age INTEGER)");
foreach my $name ('Joe', 'John', 'Brenda') {
    my $p = new Person name => $name, age => 20;
    $p->save;
}

# tests
throws_ok {
    my $p = new Person name => 'Joe'; 
    $p->save;
} qr/Value Joe violates unique constraint for attribute name \(class Person\)/, 
'unable to save a person with name "Joe" : unique value already taken';

# clean
$dbh->do("DROP TABLE person");

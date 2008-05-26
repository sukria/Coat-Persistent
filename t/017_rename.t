use strict;
use warnings;
use Test::More 'no_plan';

BEGIN { use_ok 'Coat::Persistent' }
    
use Coat::Types;

enum 'Sex' => 'Male', 'Female';

{
    package People;
    use Coat;
    use Coat::Persistent table_name => 'persons';

    has_p 'name' => (isa => 'Str');
    has_p 'age' => (isa => 'Int');
    has_p sex => (isa => 'Sex');

    has_many 'dogs', 
        class_name => 'Dog';

    package Dog;
    use Coat;
    use Coat::Persistent;


    has_p name => (isa => 'Str');
    has_p colour => (isa => 'Str');
    has_p sex => (isa => 'Sex');

    has_one 'master', 
        class_name => 'People';
}


# fixture
Coat::Persistent->map_to_dbi('csv', 'f_dir=./t/csv-test-database');
my $dbh = People->dbh;
$dbh->do("CREATE TABLE persons (id INTEGER, sex CHAR(64), name CHAR(64), age INTEGER)");
$dbh->do("CREATE TABLE dogs (id INTEGER, sex CHAR(64), name CHAR(64), colour CHAR(64))");

# TESTS 

my $joe = People->new( name => 'Joe', age => 21 );
ok( $joe->save, '$p->save' );

my $medor = Dog->new( name => 'medor', colour => 'white', sex => 'Male', master => $joe);
ok( $medor->save, '$medor->save' );

# remove the test db
$dbh->do("DROP TABLE persons");
$dbh->do("DROP TABLE dogs");
$dbh->do("DROP TABLE dbix_sequence_state");
$dbh->do("DROP TABLE dbix_sequence_release");

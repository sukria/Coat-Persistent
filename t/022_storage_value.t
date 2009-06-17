use strict;
use warnings;
use Test::More 'no_plan';

BEGIN { use_ok 'Coat::Persistent' }
    
use POSIX;
use Coat::Types;

subtype 'DateTime'
    => as 'Str'
    => where { /^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d$/ };

coerce 'DateTime'
    => from 'Int'
    => via { 
        my ($sec, $min, $hour, $day, $mon, $year) = localtime($_);
        $year += 1900;
        $mon++;
        $day = sprintf('%02d', $day);
        $mon = sprintf('%02d', $mon);
        $hour = sprintf('%02d', $hour);
        $min = sprintf('%02d', $min);
        $sec = sprintf('%02d', $sec);
        return "$year-$mon-$day $hour:$min:$sec";
    };

coerce 'Int'
    => from 'DateTime'
    => via {
        my ($year, $mon, $day, $hour, $min, $sec) = /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/;
        $year -= 1900;
        $mon--;
        return mktime(~~$sec, ~~$min, ~~$hour, ~~$day, $mon, $year);
    };
{
    package Person;
    use Coat;
    use Coat::Persistent table_name => 'people', primary_key => 'pid';

    has_p 'name' => (isa => 'Str');
    has_p 'age' => (isa => 'Int');

    has_p 'created_at' => (
        is => 'rw',
        isa => 'Int',
        store_as => 'DateTime',
    );
}


# fixture
Coat::Persistent->map_to_dbi('csv', 'f_dir=./t/csv-test-database');

my $dbh = Person->dbh;
$dbh->do("CREATE TABLE people (pid INTEGER, sex CHAR(64), name CHAR(64), age INTEGER, created_at CHAR(30))");

# TESTS 

my $t = time;
my $joe = Person->new( name => 'Joe', age => 21, created_at => $t );
my $t_str = $joe->get_storage_value_for('created_at');

is($t, $joe->created_at, "created_at is an int : $t ");
ok($t ne $t_str, "created_at storage value is : $t_str");
is($t, $joe->get_real_value_for('created_at', $joe->get_storage_value_for('created_at')), 'real_value is correctly converted');
ok($joe->save, '$joe->save');

my $joe2 = Person->find($joe->pid);
is($joe2->created_at, $t, 'created_at is still an Int when fetched');
ok($joe2->created_at(time() + 3600), 'we can play with numbers in created_at');
ok($joe2->save, '$joe->save');


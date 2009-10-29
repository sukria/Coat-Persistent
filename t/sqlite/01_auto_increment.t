use Test::More;
use Coat::Persistent;
use File::Spec;
eval "use DBD::SQLite";
plan skip_all => "DBD::SQLite needed" if $@;
my $db_file = File::Spec->rel2abs(
    File::Spec->catfile('t', 'sqlite', 'db.sqlite')); 
Coat::Persistent->map_to_dbi(sqlite => $db_file);
Coat::Persistent->disable_internal_sequence_engine;
 
plan tests => 6;

use lib 't/sqlite';
use Person;

$p = Person->create(firstname => 'Johnny', lastname => 'Smith');
ok(defined($p), '$p is defined');
isa_ok($p, 'Person');
is $p->firstname, 'Johnny', 'firstname is set';
ok defined($p->id), "id is defined";

my $p2 = Person->find($p->id);
ok(defined($p2), 'Person retreived');
is $p2->id, $p->id, 'p == p2';
Person->delete($p->id);


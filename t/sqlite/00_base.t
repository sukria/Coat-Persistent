use Test::More;
use File::Spec;

eval "use DBD::SQLite";
plan skip_all => "DBD::SQLite needed" if $@;

plan tests => 1;
use Coat::Persistent;

my $db_file = File::Spec->rel2abs("db.sqlite");
Coat::Persistent->map_to_dbi(sqlite => $db_file);
ok(defined(Coat::Persistent->dbh), "map_to_dbi worked");

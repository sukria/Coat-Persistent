# This test is here to validate that C::P works without DBIx::Sequence
use Test::More tests => 5;
use Test::Database;

{
    package Book;
    use Coat;
    use Coat::Persistent table_name => 'books';
    use Coat::Persistent::Types;

    has_p 'name' => (
        isa => 'Str',
    );

    has_p 'created_at' => (
        isa => 'Class::Date',
        store_as => 'DateTime',
    );

    sub BUILD {
        my ($self) = @_;
        $self->created_at(time());
    }
}

my ($mysql) = Test::Database->handles( dbd => 'mysql' );

SKIP: {
          
    skip "No MySQL database handle available", 5 unless defined $mysql;

    my $dbh = $mysql->dbh;
    Coat::Persistent->disable_internal_sequence_engine();
    Coat::Persistent->set_dbh($dbh);

    # Fixtures
    eval { $dbh->do("CREATE TABLE books (
        id int(11) not null auto_increment, 
        name varchar(30) not null default '',
        created_at datetime not null,
        primary key (id)
    )") };

    # tests

    my $b = Book->new(name => 'Ubik');
    ok($b->save, 'save works');
    is(1, $b->id, 'first object inserted got id 1');
    ok($b->created_at, 'field created_at is set');
    ok($b->created_at->epoch, 'created_at is a Class::Date object: '.$b->created_at->epoch);

    my $c = Book->create(name => 'Blade Runner');
    is(2, $c->id, 'second object inserted got id 2');

    # cleanup
    $dbh->do('DROP TABLE books');
};

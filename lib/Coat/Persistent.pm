package Coat::Persistent;

use Coat;
use Coat::Meta;
use Scalar::Util qw(blessed looks_like_number);
use List::Compare;
use DBI;
use DBIx::Sequence;
use Carp 'confess';
use Digest::MD5 qw(md5_base64);

use vars qw($VERSION @EXPORT $AUTHORITY);
use base qw(Exporter);

$VERSION   = '0.0_0.3';
$AUTHORITY = 'cpan:SUKRIA';
@EXPORT    = qw(has_p has_one has_many);

# Static method & stuff

# configuration place-holders
my $MAPPINGS    = {};
my $CONSTRAINTS = {};

# static accessors
sub mappings { $MAPPINGS }
sub dbh { 
    $MAPPINGS->{'!dbh'}{ $_[0] }    || 
    $MAPPINGS->{'!dbh'}{'!default'} ||
    undef
}
sub driver {
    $MAPPINGS->{'!driver'}{ $_[0] }    || 
    $MAPPINGS->{'!driver'}{'!default'} ||
    undef;
}
sub cache {
    $MAPPINGS->{'!cache'}{ $_[0] }    ||
    $MAPPINGS->{'!cache'}{'!default'} || 
    undef;
}

sub enable_cache {
    my ($class, %options) = @_;
    $class = '!default' if $class eq 'Coat::Persistent';

    # first, try to use Cache::FastMmap
    eval "use Cache::FastMmap";
    confess "Unable to load Cache::FastMmap : $@" if $@;

    # importing the module
    Cache::FastMmap->import;

    # default cache configuration
    $options{expire_time} ||= '1h';
    $options{cache_size}  ||= '10m';

    $MAPPINGS->{'!cache'}{$class} = Cache::FastMmap->new( %options );
}

sub disable_cache {
    my ($class) = @_;
    $class = '!default' if $class eq 'Coat::Persistent';
    undef $MAPPINGS->{'!cache'}{$class};
}


# This is the configration stuff, you basically bind a class to
# a DBI driver
sub map_to_dbi {
    my ( $class, $driver, @options ) = @_;
    confess "Static method cannot be called from instance" if ref $class;

    # if map_to_dbi is called from Coat::Persistent, this is the default dbh
    $class = '!default' if $class eq 'Coat::Persistent';

    my $drivers = {
        mysql => 'dbi:mysql',
        csv   => 'DBI:CSV',
    };
    confess "No such driver : $driver"
      unless exists $drivers->{$driver};

    # the csv driver needs to load the appropriate DBD module
    if ($driver eq 'csv') {
        eval "use DBD::CSV";
        confess "Unable to load DBD::CSV : $@" if $@;
        DBD::CSV->import;
    }

    $MAPPINGS->{'!driver'}{$class} = $driver;

    my ( $table, $user, $pass ) = @options;
    $driver = $drivers->{$driver};
    $MAPPINGS->{'!dbh'}{$class} =
      DBI->connect( "${driver}:${table}", $user, $pass, { PrintError => 0, RaiseError => 0 });
       
    confess "Can't connect to database ${DBI::err} : ${DBI::errstr}"
        unless $MAPPINGS->{'!dbh'}{$class};

    # if the DBIx::Sequence tables don't exist, create them
    _create_dbix_sequence_tables($MAPPINGS->{'!dbh'}{$class});
}



# The generic SQL finder, takes a SQL query and map rows returned
# to objects of the class
sub find_by_sql {
    my ( $class, $sql, @values ) = @_;
    my @objects;

    my $cache_key = md5_base64($sql . (@values ? join(',', @values) : ''));

    # if cached, try to returned a cached value
    if (defined $class->cache) {
        my $value = $class->cache->get($cache_key);
        @objects = @$value if defined $value;
    }

    # no cache found, perform the query
    unless (@objects) {
        my $dbh = $class->dbh;
        my $sth = $dbh->prepare($sql);
        $sth->execute(@values) 
            or confess "Unable to execute query $sql : " . 
               $DBI::err . ' : ' . $DBI::errstr;
        my $rows = $sth->fetchall_arrayref( {} );

        # if any rows, let's process them
        if (@$rows) {
            # we have to find out which fields are real attributes
            my $class_attr = Coat::Meta->all_attributes( $class );
            my @attrs = keys %$class_attr;
            
            # from the columns selected, where are real attributes and virtual ones?
            my $lc = new List::Compare(\@attrs, [keys %{ $rows->[0] }]);
            my @given_attr   = $lc->get_intersection;
            my @virtual_attr = $lc->get_symdiff;

            # create the object with attributes, and set virtual ones
            foreach my $r (@$rows) {
                my $obj = $class->new(map { ($_ => $r->{$_}) } @given_attr);
                $obj->{$_} = $r->{$_} for @virtual_attr;
                push @objects, $obj;
            }
        }
        
        # save to the cache if needed
        if (defined $class->cache) {
            unless ($class->cache->set($cache_key, \@objects)) {
                warn "Unable to write to cache for key : $cache_key ".
                     "; maybe upgrade the cache_size : $!";
            }
        }
    }

    return wantarray
      ? @objects
      : $objects[0];
}

# This is done to wrap the original Coat::has method so we can
# generate finders for each attribute declared
sub has_p {
    my ( $attr, %options ) = @_;
    my $caller = $options{'!caller'} || caller;
    confess "package main called has_p" if $caller eq 'main';

    # unique field ?
    $CONSTRAINTS->{'!unique'}{$caller}{$attr} = $options{unique} || 0;
    # syntax check ?
    $CONSTRAINTS->{'!syntax'}{$caller}{$attr} = $options{syntax} || undef;

    Coat::has( $attr, ( '!caller' => $caller, %options ) );

    my $finder = sub {
        my ( $class, $value ) = @_;
        confess "Cannot be called from an instance" if ref $class;
        confess "Cannot find without a value" unless defined $value;

        my $table = $class->_to_sql;

        return $class->find_by_sql("select * from $table where $attr = ?", $value);
    };
    _bind_code_to_symbol( $finder, "${caller}::find_by_${attr}" );
}

sub import {
    my $caller = caller;
    return if $caller eq 'main';

    # a Coat::Persistent object must have an id (this is the primary key)
    has_p id => ( isa => 'Int', '!caller' => $caller );

    # our caller inherits from Coat::Persistent
    eval { Coat::_extends_class( ['Coat::Persistent'], $caller ) };
    Coat::Persistent->export_to_level( 1, @_ );
}

# find() is a polymorphic method that can behaves in several ways accroding 
# to the arguments passed.
#
# Class->find() : returns all rows (select * from class)
# Class->find(12) : returns the row where id = 12
# Class->find("condition") : returns the row(s) where condition
# Class->find(["condition ?", $val]) returns the row(s) where condition

sub find {
    my ( $class, $value ) = @_;
    confess "Cannot be called from an instance" if ref $class;
    if (defined $value) {
        if (ref $value) {
            confess "Cannot handle non-aray references" if ref($value) ne 'ARRAY';
            my ($sql, @values) = @$value;
            $class->find_by_sql("select * from "
                              . $class->_to_sql
                              . " where $sql", @values);
        }
        else {
            ( looks_like_number $value )
            ? $class->find_by_id($value)
            : $class->find_by_sql("select * from ".$class->_to_sql." where $value");

        }
    }
    else {
       $class->find_by_sql( "select * from " . $class->_to_sql );
    }
}

# let's you define a relation like A.b_id -> B
# this will builds an accessor called "b" that will
# do a B->find(A->b_id)
# example :
#   package A;
#   ...
#   has_one 'foo';
#   ...
#   my $a = new A;
#   my $f = $a->foo
#
# TODO : later let the user override the bindings

sub has_one {
    my ($owned_class)   = @_;
    my $class           = caller;
    my $owned_class_sql = _to_sql($owned_class);

    # record the foreign key
    my $foreign_key = "${owned_class_sql}_id";
    has_p $foreign_key => ( isa => 'Int', '!caller' => $class );

    my $symbol = "${class}::${owned_class_sql}";
    my $code   = sub {
        my ( $self, $object ) = @_;

        # want to set the subobject
        if ( @_ == 2 ) {
            if ( defined $object ) {
                $self->$foreign_key( $object->id );
            }
            else {
                $self->$foreign_key(undef);
            }
        }

        # want to get the subobject
        else {
            return undef unless defined $self->$foreign_key;
            $owned_class->find( $self->$foreign_key );
        }
    };
    _bind_code_to_symbol( $code, $symbol );
}

# many relations means an instance of class A owns many instances
# of class B:
#     $a->bs returns B->find_by_a_id($a->id)
# * B must provide a 'has_one A' statement for this to work
sub has_many {
    my ($owned_class)   = @_;
    my $class           = caller;
    my $class_sql       = _to_sql($class);
    my $owned_class_sql = _to_sql($owned_class);

    # the accessor : $obj->things for subobject "Thing"
    my $code = sub {
        my ( $self, @list ) = @_;

        # a get
        if ( @_ == 1 ) {
            my $accessor = "find_by_${class_sql}_id";
            return $owned_class->$accessor( $self->id );
        }

        # a set
        else {
            foreach my $obj (@list) {
                confess "Not an object reference, expected $owned_class"
                  unless defined blessed $obj;
                confess "Not an object of class $owned_class (got "
                  . blessed($obj) . ")"
                  unless blessed $obj eq $owned_class;
                $obj->$class_sql($self);
                push @{ $self->{_subobjects} }, $obj;
            }
        }
    };
    _bind_code_to_symbol( $code, "${class}::${owned_class_sql}s" );
}

sub validate {
    my ($self, @args) = @_;
    my $class = ref($self);
    
    foreach my $attr (keys %{ Coat::Meta->all_attributes($class)} ) {
        # checking for syntax validation
        if (defined $CONSTRAINTS->{'!syntax'}{$class}{$attr}) {
            my $regexp = $CONSTRAINTS->{'!syntax'}{$class}{$attr};
            confess "Value \"".$self->$attr."\" for attribute \"$attr\" is not valid"
                unless $self->$attr =~ /$regexp/;
        }
        
        # checking for unique attributes on inserting (new objects)
        if ((! defined $self->id) && 
            $CONSTRAINTS->{'!unique'}{$class}{$attr}) {
            # look for other instances that already have that attribute
            my @items = $class->find(["$attr = ?", $self->$attr]);
            confess "Value ".$self->$attr." violates unique constraint "
                  . "for attribute $attr (class $class)"
                if @items;
        }
    }

}

sub delete {
    my ($self, $id) = @_;
    my $class  = ref $self || $self;
    my $dbh    = $class->dbh;

    confess "Cannot delete without an id" 
        if (!ref $self && !defined $id);
    
    confess "Cannot delete without a mapping defined for class " . ref $self
      unless defined $dbh;

    $id = $self->id if ref($self);

    confess "Cannot delete without a defined id" 
        unless defined $id;

    $dbh->do("delete from ".$class->_to_sql." where id = $id");
}

# serialize the instance and save it with the mapper defined
sub save {
    my ($self) = @_;
    my $class  = ref $self;
    my $dbh    = $class->dbh;

    confess "Cannot save without a mapping defined for class " . ref $self
      unless defined $dbh;

    # first call validate to check the object is sane
    $self->validate();

    my $table = $self->_to_sql;
    my @values;
    my @fields = keys %{ Coat::Meta->all_attributes( ref $self ) };

    # if we have an id, update
    if ( defined $self->id ) {
        @values = map { $self->$_ } @fields;
        my $sql =
            "update $table set "
          . join( ", ", map { "$_ = ?" } @fields )
          . " where id = ?";

        my $sth = $dbh->prepare($sql);
        $sth->execute( @values, $self->id )
          or confess "Unable to execute query \"$sql\" : $!";
    }

    # no id, insert with a valid id
    else {
        $self->id( $self->_next_id );

        my $sql =
            "insert into $table ("
          . ( join ", ", @fields )
          . ") values ("
          . ( join ", ", map { '?' } @fields ) . ")";

        foreach my $field (@fields) {
            push @values, $self->$field;
        }

        my $sth = $dbh->prepare($sql);
        $sth->execute(@values)
          or confess "Unable to execute query : \"$sql\"  : [$!] with "
          . join( ", ", @values );
    }

    # if subobjects defined, save them
    if ( $self->{_subobjects} ) {
        foreach my $obj ( @{ $self->{_subobjects} } ) {
            $obj->save;
        }
        delete $self->{_subobjects};
    }
    return $self->id;
}


##############################################################################
# Private methods

# instance method & stuff
sub _bind_code_to_symbol {
    my ( $code, $symbol ) = @_;
    {
        no strict 'refs';
        no warnings 'redefine', 'prototype';
        *$symbol = $code;
    }
}

sub _to_class {
    join '::', map { ucfirst $_ } split '_', $_[0];
}

sub _to_sql {
    my $table = ( ref $_[0] ) ? lc ref $_[0] : lc $_[0];
    $table =~ s/::/_/g;
    return $table;
}

sub _lock_write {
    my ($self) = @_;
    my $class = ref $self;
    return 1 if $class->driver ne 'mysql';

    my $dbh   = $class->dbh;
    my $table = $self->_to_sql;
    $dbh->do("LOCK TABLE $table WRITE")
      or confess "Unable to lock table $table";
}

sub _unlock {
    my ($self) = @_;
    my $class = ref $self;
    return 1 if $class->driver ne 'mysql';

    my $dbh = $class->dbh;
    $dbh->do("UNLOCK TABLES")
      or confess "Unable to lock tables";
}

sub _next_id {
    my ($self) = @_;
    my $class = ref $self;
    
    my $table = $self->_to_sql;
    my $dbh   = $class->dbh;

    my $sequence = new DBIx::Sequence({ dbh => $dbh });
    my $id = $sequence->Next($table);
    return $id;
}

# DBIx::Sequence needs two tables in the schema,
# this private function create them if needed.
sub _create_dbix_sequence_tables($) {
    my ($dbh) = @_;

    # dbix_sequence_state exists ?
    unless (_table_exists($dbh, 'dbix_sequence_state')) {
        # nope, create!
        $dbh->do("CREATE TABLE dbix_sequence_state (dataset varchar(50), state_id int(11))")
            or confess "Unable to create table dbix_sequence_state $DBI::errstr";
    }

    # dbix_sequence_release exists ?
    unless (_table_exists($dbh, 'dbix_sequence_release')) {
        # nope, create!
        $dbh->do("CREATE TABLE dbix_sequence_release (dataset varchar(50), released_id int(11))")
            or confess "Unable to create table dbix_sequence_release $DBI::errstr";
    }
}

# This is the best way I found to check if a table exists, with a portable SQL
# If you have better, tell me!
sub _table_exists($$) {
    my ($dbh, $table) = @_;
    my $sth = $dbh->prepare("select count(*) from $table");
    return 0 unless defined $sth;
    $sth->execute or return 0;
    my $nb_rows = $sth->fetchrow_hashref;
    return defined $nb_rows;
}

1;
__END__

=pod

=head1 NAME

Coat::Persistent -- Simple Object-Relational mapping for Coat objects

=head1 DESCRIPTION

Coat::Persistent is an object to relational-databases mapper, it allows you to
build instances of Coat objects and save them into a database transparently.

You basically define a mapping rule, either global or per-class and play with
your Coat objects without bothering with SQL for simple cases (selecting,
inserting, updating). 

Coat::Peristent lets you use SQL if you want to, considering SQL is the best
language when dealing with compelx queries.

=head1 WHY THIS MODULE ?

There are already very good ORMs for Perl available in the CPAN so why did this
module get added?

Basically for one reason: I wanted a very simple way to build persistent
objects for Coat and wanted something near the smart design of Rails'ORM
(ActiveRecord). Moreover I wanted my ORM to let me send SQL requests if I
wanted to (so I can do basic actions without SQL and complex queries with SQL).

This module is the result of my experiments of mixing DBI and Coat together,
although it is a developer release, it works pretty well and fit my needs.

This module is expected to change in the future (don't consider the API to be
stable at this time), and to grow (hopefully).

=head1 DATA BACKEND

The concept behing this module is the same behind the ORM of Rails : all your
tables must have a primary key named B<id>. This may become configurable in
future versions, but in this developer release this is not.

Your table names must be named like the package they map, with the following
rules applied : lower case, replace "::" by "_". For instance a class Foo::Bar
should be mapped to a table named "foo_bar".

All foreign key must be named "<table>_id" where table is the name if the
class mapped formated like said above.

=head1 CONFIGURATION

=head2 DBI MAPPING

You have to tell Coat::Persistent how to map a class to a DBI driver. You can
either choose to define a default mapper (in most of the cases this is what
you want) or define a mapper for a specific class.

=over 4 

=item B<Coat::Persistent-E<gt>map_to_dbi $driver, @options >

This will set the default mapper. Every class that hasn't a specific mapper set
will use this one.

=item B<__PACKAGE__-E<gt>map_to_dbi $driver, @options >

This will set a mapper for the current class.

=back

Supported values for B<$driver> are the following :

=over 4

=item I<csv> : this will use DBI's "DBD:CSV" driver to map your instances to a CSV
file. B<@options> must contains a string as its first element being like the
following: "f_dir=<DIRECTORY>" where DIRECTORY is the directory where to store
de CSV files.

Example:

    packahe Foo;
    use Coat::Persistent;
    __PACKAGE__->map_to_dbi('csv', 'f_dir=./t/csv-directory');

=item I<mysql> : this will use DBI's "dbi:mysql" driver to map your instances
to a MySQL database. B<@options> must be a list that contains repectively: the
database name, the database user, the database password.

Example:

    package Foo;
    use Coat::Persistent;
    __PACKAGE__->map_to_dbi('mysql' => 'dbname', 'dbuser', 'dbpass' );

=back

=head2 CACHING

Since version 0.0_0.2, Coat::Persistent provides a simple way to cache the
results of underlying SQL requests. By default, no cache is performed.

You can either choose to enable the caching system for all the classes (global
cache) or for a specific class. You could also define different cache
configurations for each class.

When the cache is enabled, every SQL query generated by Coat::Persistent is
first looked through the cache collection. If the query is found, its cached
result is returned; if not, the query is executed with the appropriate DBI
mapper and the result is cached.

The backend used by Coat::Persistent for caching is L<Cache::FastMmap> which
is able to expire the data on his own. Coat::Persistent lets you access the
Cache::FastMmap object through a static accessor :

=over 4

=item B<Coat::Persistent-E<gt>cache> : return the default cache object

=item B<__PACKAGE__-E<gt>cache> : return the cache object for the class __PACKAGE__

=back

To set a global cache system, use the static method B<enable_cache>. This
method receives a hash table with options to pass to the Cache::FastMmap
constructor.

Example :

    Coat::Persistent->enable_cache(
        expire_time => '1h',
        cache_size  => '50m',
        share_file  => '/var/cache/myapp.cache',
    );

It's possible to disable the cache system with the static method
B<disable_cache>.

See L<Cache::FastMmap> for details about available constructor's options.

=head1 METHODS

=over 4

=item B<has_p $name =E<gt> %options>

Coat::Persistent classes have the keyword B<has_p> to define persistent
attributes. Attributes declared with B<has_p> are valid Coat attributes and
take the same options as Coat's B<has> method. (Refer to L<Coat> for details).

All attributes declared with B<has_p> must exist in the mapped data backend
(they are a column of the table mapped to the class).

=item B<has_one $class>

Tells that current class owns a subobject of the class $class. This will allow
you to set and get a subobject transparently.

The backend must have a foreign key to the table of $class.

Example:

    package Foo;
    use Coat::Persistent;

    has_one 'Bar';

    package Bar;
    use Coat::Persistent;

    my $foo = new Foo;
    $foo->bar(new Bar);

=item B<has_many $class>

This is the same as has_one but says that many items are bound to one
instance of the current class.

The backend of class $class must provide a foreign key to the current class.

=head1 SEE ALSO

See L<Coat> for all the meta-class documentation. See L<Cache::FastMmap> for
details about the cache objects provided.

=head1 AUTHOR

This module was written by Alexis Sukrieh E<lt>sukria+perl@sukria.netE<gt>.

=head1 COPYRIGHT AND LICENSE

Copyright 2007 by Alexis Sukrieh.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

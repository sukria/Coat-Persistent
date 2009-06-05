package Coat::Persistent;

# Coat & friends
use Coat;
use Coat::Meta;
use Coat::Persistent::Meta;
use Carp 'confess';

use Data::Dumper;

# Low-level helpers
use Digest::MD5 qw(md5_base64);
use Scalar::Util qw(blessed looks_like_number);
use List::Compare;

# DBI & SQL related
use DBI;
use DBIx::Sequence;
use SQL::Abstract;

# Constants
use constant CP_ENTRY_NEW => 0;
use constant CP_ENTRY_EXISTS => 1;

# Module meta-data
use vars qw($VERSION @EXPORT $AUTHORITY);
use base qw(Exporter);

$VERSION   = '0.104';
$AUTHORITY = 'cpan:SUKRIA';
@EXPORT    = qw(has_p has_one has_many);

# The SQL::Abstract object
my $sql_abstract = SQL::Abstract->new;

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

# A singleton that stores the driver/module mappings
# The ones here are default drivers that are known to be compliant
# with Coat::Persistent.
# Any DBI driver should work though.
my $drivers = {
    csv    => 'DBI:CSV',
    mysql  => 'dbi:mysql',
    sqlite => 'dbi:SQLite',
};
sub drivers { $drivers }

# Accessor to a driver
sub get_driver {
    my ($class, $driver) = @_;
    confess "driver needed" unless $driver;
    return $class->drivers->{$driver};
}

# This lets you add the DBI driver you want to use
sub add_driver {
    my ($class, $driver, $module) = @_;
    confess "driver and module needed" unless $driver and $module;
    $class->drivers->{$driver} = $module;
}

# This is the configration stuff, you basically bind a class to
# a DBI driver
sub map_to_dbi {
    my ( $class, $driver, @options ) = @_;
    confess "Static method cannot be called from instance" if ref $class;

    # if map_to_dbi is called from Coat::Persistent, this is the default dbh
    $class = '!default' if $class eq 'Coat::Persistent';

    my $drivers = Coat::Persistent->drivers;

    confess "No such driver : $driver, please register the driver first with add_driver()"
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


# This is done to wrap the original Coat::has method so we can
# generate finders for each attribute declared
# 
# ActiveRecord chose to make attribute's finders dynamic, the functions are built
# at runtime whenever they're called. In Perl this could have been done with 
# AUTOLOAD, but that sucks. Doing that would mean crappy performances;
# defining the method in the package's namespace is far more efficient.
#
# The only case where I see AUTOLOAD is the good choice is for finders
# made by mixing more than one attribute (find_by_foo_and_bar). 
# Then, yes AUTOLOAD is a good choice, but for all the ones we know we need 
# them, I disagree.
sub has_p {
    my ( $attr, %options ) = @_;
    my $caller = $options{'!caller'} || caller;
    confess "package main called has_p" if $caller eq 'main';

    # unique field ?
    $CONSTRAINTS->{'!unique'}{$caller}{$attr} = $options{unique} || 0;
    # syntax check ?
    $CONSTRAINTS->{'!syntax'}{$caller}{$attr} = $options{syntax} || undef;

    Coat::has( $attr, ( '!caller' => $caller, %options ) );
    Coat::Persistent::Meta->attribute($caller, $attr);

    # find_by_
    my $sub_find_by = sub {
        my ( $class, $value ) = @_;
        confess "Cannot be called from an instance" if ref $class;
        confess "Cannot find without a value" unless defined $value;
        my $table = Coat::Persistent::Meta->table_name($class);
        my ($sql, @values) = $sql_abstract->select($table, '*', {$attr => $value});
        return $class->find_by_sql($sql, @values);
    };
    _bind_code_to_symbol( $sub_find_by, 
                          "${caller}::find_by_${attr}" );

    # find_or_create_by_
    my $sub_find_or_create = sub {
        # if 2 args : we're given the value of $attr only
        if (@_ == 2) {
            my ($class, $value) = @_;
            my $obj = $class->find(["$attr = ?", $value]);
            return $obj if defined $obj;
            $class->create($attr => $value);
        }
        # more than 2 args : this is a hash of attributes to look for
        else {
            my ($class, %attrs) = @_;
            confess "Cannot find_or_create_by_$attr without $attr" 
                unless exists $attrs{$attr};
            my $obj = $class->find(["$attr = ?", $attrs{$attr}]);
            return $obj if defined $obj;
            $class->create(%attrs);
        }
    };
    _bind_code_to_symbol( $sub_find_or_create, 
                          "${caller}::find_or_create_by_${attr}" );

    # find_or_initialize_by_
    my $sub_find_or_initialize = sub {
        # if 2 args : we're given the value of $attr only
        if (@_ == 2) {
            my ($class, $value) = @_;
            my $obj = $class->find(["$attr = ?", $value]);
            return $obj if defined $obj;
            $class->new($attr => $value);
        }
        # more than 2 args : this is a hash of attributes to look for
        else {
            my ($class, %attrs) = @_;
            confess "Cannot find_or_initialize_by_$attr without $attr" 
                unless exists $attrs{$attr};
            my $obj = $class->find(["$attr = ?", $attrs{$attr}]);
            return $obj if defined $obj;
            $class->new(%attrs);
        }
    };
    _bind_code_to_symbol( $sub_find_or_initialize, 
                          "${caller}::find_or_initialize_by_${attr}" );
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
    my ($name, %options) = @_;
    my $class = caller;

    my $owned_class       = $options{class_name} || $name;
    my $owned_table_name  = Coat::Persistent::Meta->table_name($owned_class);
    my $owned_primary_key = Coat::Persistent::Meta->primary_key($owned_class);
    
    my $attr_name = (defined $options{class_name}) ? $name : $owned_table_name ;

    # record the foreign key
    my $foreign_key = $owned_table_name . '_' . $owned_primary_key;
    has_p $foreign_key => ( isa => 'Int', '!caller' => $class );

    my $symbol = "${class}::${attr_name}";
    my $code   = sub {
        my ( $self, $object ) = @_;

        # want to set the subobject
        if ( @_ == 2 ) {
            if ( defined $object ) {
                $self->$foreign_key( $object->$owned_primary_key );
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

    # save the accessor defined for that subobject
    Coat::Persistent::Meta->accessor( $class => $attr_name );
}

# many relations means an instance of class A owns many instances
# of class B:
#     $a->bs returns B->find_by_a_id($a->id)
# * B must provide a 'has_one A' statement for this to work
sub has_many {
    my ($name, %options)   = @_;
    my $class = caller;

    my $owned_class       = $options{class_name} || $name;

    # get the SQL table names and primary keys we need 
    my $table_name        = Coat::Persistent::Meta->table_name($class);
    my $primary_key       = Coat::Persistent::Meta->primary_key($class);
    my $owned_table_name  = Coat::Persistent::Meta->table_name($owned_class);
    my $owned_primary_key = Coat::Persistent::Meta->primary_key($owned_class);
    
    my $attr_name = (defined $options{class_name}) 
                  ? $name 
                  : $owned_table_name.'s' ;

    # FIXME : have to pluralize properly and let the user
    # disable the pluralisation.
    # the accessor : $obj->things for subobject "Thing"
    my $code = sub {
        my ( $self, @list ) = @_;

        # a get
        if ( @_ == 1 ) {
            my $accessor = "find_by_${table_name}_${primary_key}";
            return $owned_class->$accessor( $self->$primary_key );
        }

        # a set
        else {
            foreach my $obj (@list) {
                # is the object made of something appropriate?
                confess "Not an object reference, expected $owned_class, got ($obj)"
                  unless defined blessed $obj;
                confess "Not an object of class $owned_class (got "
                  . blessed($obj) . ")"
                  unless blessed $obj eq $owned_class;
                
                # then set 
                my $accessor = Coat::Persistent::Meta->accessor( $owned_class) || $table_name;
                $obj->$accessor($self);
                push @{ $self->{_subobjects} }, $obj;
            }
            return scalar(@list) == scalar(@{$self->{_subobjects}});
        }
    };
    _bind_code_to_symbol( $code, "${class}::${attr_name}" );
}

# When Coat::Persistent is imported, a couple of actions have to be 
# done. Mostly: declare the default primary key of the model, the table
# name it maps.
sub import {
    my ($class, @stuff) = @_;
    my %options;
    %options = @stuff if @stuff % 2 == 0;

    # Don't do our automagick inheritance if main is calling us or if the
    # class has already been registered
    my $caller = caller;
    return if $caller eq 'main';
    return if defined Coat::Persistent::Meta->registry( $class );
    
    # now, our caller inherits from Coat::Persistent
    eval { Coat::_extends_class( ['Coat::Persistent'], $caller ) };

    # default values for mapping rules
    $options{primary_key} ||= 'id';
    $options{table_name}  ||= $caller->_to_sql;

    # save the meta information obout the model mapping
    Coat::Persistent::Meta->table_name($caller, $options{table_name});
    Coat::Persistent::Meta->primary_key($caller, $options{primary_key});

    # a Coat::Persistent object must have a the primary key)
    has_p $options{primary_key} => ( isa => 'Int', '!caller' => $caller );

    # we have a couple of symbols to export outside
    Coat::Persistent->export_to_level( 1, ($class, @EXPORT) );
}

# find() is a polymorphic method that can behaves in several ways accroding 
# to the arguments passed.
#
# Class->find() : returns all rows (select * from class)
# Class->find(12) : returns the row where id = 12
# Class->find("condition") : returns the row(s) where condition
# Class->find(["condition ?", $val]) returns the row(s) where condition
#
# You can also pass an as your last argument, this will be the options
# Class->find(..., \%options) 

sub find {
    # first of all, if the last arg is a HASH, its our options
    # then, pop it so it's not processed anymore.
    my %options;
    %options = %{ pop @_ } 
        if (defined $_[$#_] && ref($_[$#_]) eq 'HASH');

    # then, fetch the args
    my ( $class, $value, @rest ) = @_;
    confess "Cannot be called from an instance" if ref $class;

    # get the corresponfing SQL names
    my $primary_key = Coat::Persistent::Meta->primary_key($class);
    my $table_name  = Coat::Persistent::Meta->table_name($class);

    # handling of the options given
    my $select = $options{'select'} || '*';
    my $from   = $options{'from'}   || $table_name;
    my $group  = "GROUP BY " . $options{group} if defined $options{group};
    my $order  = "ORDER BY " . $options{order} if defined $options{order};
    my $limit  = "LIMIT "    . $options{limit} if defined $options{limit};

    
    # now building the sql tail of our future query
    my $tail = " ";
    $tail   .= "$group " if defined $group;
    $tail   .= "$order " if defined $order;
    $tail   .= "$limit " if defined $limit;

    if (defined $value) {
        if (ref $value) {
            confess "Cannot handle non-array references" if ref($value) ne 'ARRAY';
            # we don't use SQL::Abstract there, because we have a SQL
            # statement with "?" and a list of values
            my ($sql, @values) = @$value;
            $class->find_by_sql(
                "select $select from $from where $sql $tail", @values);
        }
        # we don't have a list, so let's find out what's given 
        else {
            # the first item looks like a number (then it's an ID)
            if (looks_like_number $value) {
                my ($sql, @values) = $sql_abstract->select( 
                                        $from, 
                                        $select, 
                                        { $primary_key => [$value, @rest] });
                return $class->find_by_sql($sql.$tail, @values);
            }
            # else, it a user-defined SQL condition
            else {
                my ($sql, @values) = $sql_abstract->select($from, $select, $value);
                $class->find_by_sql($sql.$tail, @values);
            }
        }
    }
    else {
       $class->find_by_sql( $sql_abstract->select( $from, $select ).$tail);
    }
}

# The generic SQL finder, takes a SQL query and map rows returned
# to objects of the class
sub find_by_sql {
    my ( $class, $sql, @values ) = @_;
    my @objects;
#    warn "find_by_sql\n\tsql: $sql\n\tval: @values\n";

    # if cached, try to returned a cached value
    if (defined $class->cache) {
        my $cache_key = md5_base64($sql . (@values ? join(',', @values) : ''));
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
            my @attrs = Coat::Persistent::Meta->linearized_attributes( $class );
            my $lc = new List::Compare(\@attrs, [keys %{ $rows->[0] }]);
            my @given_attr   = $lc->get_intersection;
            my @virtual_attr = $lc->get_symdiff;

            # create the object with attributes, and set virtual ones
            foreach my $r (@$rows) {

                my $obj = $class->new(map { ($_ => $r->{$_}) } @given_attr);
                $obj->init_on_find();
                foreach my $field (@virtual_attr) {
                    $obj->{$field} = $r->{$field};
                }

                $obj->{_db_state} = CP_ENTRY_EXISTS;
                push @objects, $obj;
            }
        }
        
        # save to the cache if needed
        if (defined $class->cache) {
            my $cache_key = md5_base64($sql . (@values ? join(',', @values) : ''));
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


sub init_on_find {
}

sub BUILD {
    my ($self) = @_;
    $self->{_db_state} = CP_ENTRY_NEW;
}

sub validate {
    my ($self, @args) = @_;
    my $class = ref($self);
    my $table_name  = Coat::Persistent::Meta->table_name($class);
    my $primary_key = Coat::Persistent::Meta->primary_key($class);
    
    foreach my $attr (Coat::Persistent::Meta->linearized_attributes($class) ) {
        # checking for syntax validation
        if (defined $CONSTRAINTS->{'!syntax'}{$class}{$attr}) {
            my $regexp = $CONSTRAINTS->{'!syntax'}{$class}{$attr};
            confess "Value \"".$self->$attr."\" for attribute \"$attr\" is not valid"
                unless $self->$attr =~ /$regexp/;
        }
        
        # checking for unique attributes on inserting (new objects)
        if ((! defined $self->$primary_key) && 
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
    my $table_name  = Coat::Persistent::Meta->table_name($class);
    my $primary_key = Coat::Persistent::Meta->primary_key($class);

    confess "Cannot delete without an id" 
        if (!ref $self && !defined $id);
    
    confess "Cannot delete without a mapping defined for class " . ref $self
      unless defined $dbh;

    # if the argument given is an object, fetch its id
    $id = $self->$primary_key if ref($self);

    # at this, point, we must have an id
    confess "Cannot delete without a defined id" 
        unless defined $id;

    # delete the stuff
    $dbh->do("delete from ".$table_name." where $primary_key = $id");
}

# create is an alias for new + save, it can hande simple 
# and multiple creation.
# Class->create( foo => 'x', bar => 'y'); # simple creation
# Class->create([ { foo => 'x' }, {...}, ... ]); # multiple creation
sub create {
    # if only two args, we should have an ARRAY containing HASH
    if (@_ == 2) {
        my ($class, $values) = @_;
        confess "create received only two args but no ARRAY" 
            unless ref($values) eq 'ARRAY';
        $class->create(%$_) for @$values;
    }
    else {
        my ($class, %values) = @_;
        my $obj = $class->new(%values);
        $obj->save;
        $obj;
    }
}

# serialize the instance and save it with the mapper defined
sub save {
    my ($self) = @_;
    my $class  = ref $self;
    my $dbh    = $class->dbh;
    my $table_name  = Coat::Persistent::Meta->table_name($class);
    my $primary_key = Coat::Persistent::Meta->primary_key($class);
    #warn "save\n\ttable_name: $table_name\n\tprimary_key: $primary_key\n";

    confess "Cannot save without a mapping defined for class " . ref $self
      unless defined $dbh;

    # make sure the object is sane
    $self->validate();

    # all the attributes of the class
    my @fields = Coat::Persistent::Meta->linearized_attributes( ref $self );
    # a hash containing attr/value pairs for the current object.
    my %values = map { $_ => $self->$_ } @fields;

    # if not a new object, we have to update
    if ( $self->_db_state == CP_ENTRY_EXISTS ) {

        # generate the SQL
        my ($sql, @values) = $sql_abstract->update(
            $table_name, \%values, { $primary_key => $self->$primary_key});
        # execute the query
        my $sth = $dbh->prepare($sql);
        $sth->execute( @values )
          or confess "Unable to execute query \"$sql\" : $DBI::errstr";
    }

    # new object, insert
    else {
        # if the id has been touched, trigger an error, that's not possible
        # with the use of DBIx::Sequence
        if ($self->{id}) {
            confess "The id has been set on a newborn object of class ".ref($self).", cannot save, id would change";
        }

        # get our ID from the sequence
        $self->$primary_key( $self->_next_id );
    
        # generate the SQL
        my ($sql, @values) = $sql_abstract->insert(
            $table_name, { %values, $primary_key => $self->$primary_key });

        # execute the query
        #warn "sql: $sql ".join(', ', @values);
        my $sth = $dbh->prepare($sql);
        $sth->execute( @values )
          or confess "Unable to execute query \"$sql\" : $DBI::errstr";

        $self->{_db_state} = CP_ENTRY_EXISTS;
    }

    # if subobjects defined, save them
    if ( $self->{_subobjects} ) {
        foreach my $obj ( @{ $self->{_subobjects} } ) {
            $obj->save;
        }
        delete $self->{_subobjects};
    }
    return $self->$primary_key;
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

# Takes a classname and translates it into a database table name.
# Ex: Class::Foo -> class_foo
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
    my $table = Coat::Persistent::Meta->table_name($class);
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
    
    my $table = Coat::Persistent::Meta->table_name($class);
    my $dbh   = $class->dbh;

    my $sequence = new DBIx::Sequence({ dbh => $dbh });
    my $id = $sequence->Next($table);
    return $id;
}

# Returns a constant describing if the object exists or not
# already in the underlying DB
sub _db_state {
    my ($self) = @_;
    return $self->{_db_state} ||= CP_ENTRY_NEW;
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

The underlying target of this module is to port the whole ActiveRecord::Base
API to Perl. If you find the challenge and the idea interesting, feel free to 
contact me for giving a hand. 

This is still a development version and should not be used in production
environment. 

=head1 DATA BACKEND

The concept behing this module is the same behind the ORM of Rails : there are
conventions that tell how to translate a model meta-information into a SQL
one :

The conventions implemented in Coat::Persistent are the following:

=over 4

=item The primary key of the tables mapped should be named 'id'.

=item Your table names must be named like the package they map, with the following
rules applied : lower case, replace "::" by "_". For instance a class Foo::Bar
should be mapped to a table named "foo_bar".

=item All foreign keys must be named "<table>_id" where table is the name if the
class mapped formated like said above.

=back

You can overide those conventions at import time:

    package My::Model;
    use Coat;
    use Coat::Persistent 
            table_name  => 'mymodel', # default would be 'my_model'
            primary_key => 'mid';     # default would be 'id'

=head1 CONFIGURATION

=head2 DBI MAPPING

You have to tell Coat::Persistent how to map a class to a DBI driver. You can
either choose to define a default mapper (in most of the cases this is what
you want) or define a mapper for a specific class.

In order for your mapping to be possible, the driver you use must be known by
Coat::Persistent, you can modify its driver mapping matrix if needed.

=over 4

=item B<drivers( )>

Return a hashref representing all the drivers mapped.

  MyClass->drivers;

=item B<get_driver( $name )>

Return the Perl module of the driver defined for the given driver name.
  
  MyClass->get_driver( 'mysql' );

=item B<add_driver( $name, $module )>

Add or replace a driver mapping rule. 

  MyClass->add_driver( sqlite => 'dbi:SQLite' );

=back

Then, you can use your driver in mapping rules. Basically, the mapping will
generate a DBI-E<gt>connect() call.

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

=head2 CLASS CONFIGURATION

The following pragma are provided to configure the mapping that will be 
done between a table and the class.

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

=back

=head2 CLASS METHODS

The following methods are inherited by Coat::Persistent classes, they provide
features for accessing and touching the database below the abstraction layer.
Those methods must be called in class-context.

=over 4 

=item I<Find by id>: This can either be a specific id or a list of ids (1, 5,
6)

=item I<Find in scalar context>: This will return the first record matched by
the options used. These options can either be specific conditions or merely an
order. If no record can be matched, undef is returned.

=item I<Find in list context>: This will return all the records matched by the
options used. If no records are found, an empty array is returned.

=back

The following options are supported :

=over 4

=item B<select>: By default, this is * as in SELECT * FROM, but can be
changed.

=item B<from>: By default, this is the table name of the class, but can be changed
to an alternate table name (or even the name of a database view). 

=item B<order>: An SQL fragment like "created_at DESC, name".

=item B<group>: An attribute name by which the result should be grouped. 
Uses the GROUP BY SQL-clause.

=item B<limit>: An integer determining the limit on the number of rows that should
be returned.

=back

Examples without options:

    my $obj = Class->find(23);
    my @list = Class->find(1, 23, 34, 54);
    my $obj = Class->find("field = 'value'");
    my $obj = Class->find(["field = ?", $value]);

Example with options:

    my @list = Class->find($condition, { order => 'field1 desc' })

=back

=item B<find_by_sql($sql, @bind_values>

Executes a custom sql query against your database and returns all the results
if in list context, only the first one if in scalar context.

If you call a complicated SQL query which spans multiple tables the columns
specified by the SELECT that aren't real attributes of your model will be
provided in the hashref of the object, but you won't have accessors.

The sql parameter is a full sql query as a string. It will be called as is,
there will be no database agnostic conversions performed. This should be a
last resort because using, for example, MySQL specific terms will lock you to
using that particular database engine or require you to change your call if
you switch engines.

Example:

    my $obj = Class->find_by_sql("select * from class where $cond");
    my @obj = Class->find_by_sql("select * from class where col = ?", 34);

=item B<create>

Creates an object (or multiple objects) and saves it to the database. 

The attributes parameter can be either be a hash or an array of hash-refs. These
hashes describe the attributes on the objects that are to be created.

Examples

  # Create a single new object
  User->create(first_name => 'Jamie')
  
  # Create an Array of new objects
  User->create([{ first_name => 'Jamie'}, { first_name => 'Jeremy' }])


=back

=head2 INSTANCE METHODS

The following methods are provided by objects created from the class.
Those methods must be called in instance-context.

=over 4 

=item B<save>

If no record exists, creates a new record with values matching those of the
object attributes.
If a record does exist, updates the record with values matching those
of the object attributes.

Returns the id of the object saved. 

=back

=head1 SEE ALSO

See L<Coat> for all the meta-class documentation. See L<Cache::FastMmap> for
details about the cache objects provided.

=head1 AUTHOR

This module was written by Alexis Sukrieh E<lt>sukria@cpan.orgE<gt>.
Quite everything implemented in this module was inspired from
ActiveRecord::Base's API (from Ruby on Rails).

Parts of the documentation are also taken from ActiveRecord::Base when
appropriate.

=head1 COPYRIGHT AND LICENSE

Copyright 2007 by Alexis Sukrieh.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

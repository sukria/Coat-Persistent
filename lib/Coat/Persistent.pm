package Coat::Persistent;

use Coat;
use Coat::Meta;
use Scalar::Util 'blessed';

use DBI;
use DBD::CSV;
use Carp 'confess';

use vars qw($VERSION @EXPORT $AUTHORITY);
use base qw(Exporter);

$AUTHORITY = 'cpan:SUKRIA';
$VERSION   = '0.0_0.1';
@EXPORT    = qw(has_p owns_one owns_many);

# Static method & stuff

my $MAPPINGS = {};
my $FIELDS   = {};

sub mappings { $MAPPINGS }
sub dbh { $MAPPINGS->{'!dbh'}{ $_[0] } || $MAPPINGS->{'!dbh'}{'!default'} }

sub driver {
    $MAPPINGS->{'!driver'}{ $_[0] } || $MAPPINGS->{'!driver'}{'!default'};
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

    $MAPPINGS->{'!driver'}{$class} = $driver;

    my ( $table, $user, $pass ) = @options;
    $driver = $drivers->{$driver};
    $MAPPINGS->{'!dbh'}{$class} =
      DBI->connect( "${driver}:${table}", $user, $pass );
}

# The generic SQL finder, takes a SQL query and map rows returned
# to objects of the class
sub find_by_sql {
    my ( $class, $sql, @values ) = @_;

    my $dbh = $class->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values) or confess "Unable to execute query $sql";
    my $rows = $sth->fetchall_arrayref( {} );

    my @objects = map {
        my $obj = $class->new;

        # column returned by the query that are valid attrs are set,
        # other are set as virtual attr (without the accessor).
        foreach my $attr ( keys %$_ ) {
            Coat::Meta->has( $class, $attr )
              ? $obj->$attr( $_->{$attr} )
              : $obj->{$attr} = $_->{$attr};
        }
        $obj;
    } @$rows;
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

    Coat::has( $attr, ( '!caller' => $caller, %options ) );

    my $finder = sub {
        my ( $class, $value ) = @_;
        confess "Cannot be called from an instance" if ref $class;
        confess "Cannot find without a value" unless defined $value;

        my $table = $class->_to_sql;
        $class->find_by_sql( "select * from $table where $attr = ?", $value );
    };
    _bind_code_to_symbol($finder, "${caller}::find_by_${attr}");
}

sub import {
    my $caller = caller;
    return if $caller eq 'main';

    # a Coat::Persistent object must have an id (this is the primary key)
    has_p id => ( isa => 'Int', '!caller' => $caller );

    # our caller inherits from Coat::Persistent
    Coat::_extends_class( ['Coat::Persistent'], $caller );
    Coat::Persistent->export_to_level( 1, @_ );
}

sub find {
    my ( $class, $id ) = @_;
    confess "Cannot be called from an instance" if ref $class;
    confess "Cannot find without an id" unless defined $id;
    $class->find_by_id($id);
}

# let's you define a relation like A.b_id -> B
# this will builds an accessor called "b" that will
# do a B->find(A->b_id)
# example :
#   package A;
#   ...
#   owns_one 'foo';
#   ...
#   my $a = new A;
#   my $f = $a->foo
#
# TODO : later let the user override the bindings

sub owns_one {
    my ($owned_class) = @_;
    my $class = caller;
    my $owned_class_sql = _to_sql($owned_class);

    # record the foreign key
    my $foreign_key = "${owned_class_sql}_id";
    has_p $foreign_key => ( isa => 'Int', '!caller' => $class );

    my $symbol             = "${class}::${owned_class_sql}";
    my $code = sub {
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
    _bind_code_to_symbol($code, $symbol); 
}

# many relations means an instance of class A owns many instances
# of class B: 
#     $a->bs returns B->find_by_a_id($a->id)
# * B must provide a 'owns_one A' statement for this to work
sub owns_many {
    my ($owned_class) = @_;
    my $class = caller;
    my $class_sql = _to_sql($class);
    my $owned_class_sql = _to_sql($owned_class);

    # the accessor : $obj->things for subobject "Thing"
    my $code = sub {
        my ($self, @list) = @_;
        # a get
        if (@_ == 1) {
            my $accessor = "find_by_${class_sql}_id";
            return $owned_class->$accessor($self->id);
        }

        # a set
        else {
            foreach my $obj (@list) {
                confess "Not an object reference, expected $owned_class"
                    unless defined blessed $obj;
                confess "Not an object of class $owned_class (got "
                        . blessed($obj)
                        .")"
                    unless blessed $obj eq $owned_class;
                $obj->$class_sql($self);
                push @{$self->{_subobjects}}, $obj
            }
        }
    };
    _bind_code_to_symbol( $code, "${class}::${owned_class_sql}s" );
}

# instance method & stuff
sub _bind_code_to_symbol
{
    my ($code, $symbol) = @_;
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
    my $dbh   = $class->dbh;
    my $table = $self->_to_sql;

    my $sth =
      $dbh->prepare( "select id as last_id "
          . "from $table "
          . "order by last_id "
          . "desc limit 1" );
    $sth->execute;
    my $row = $sth->fetchrow_hashref;

    return ( $row->{last_id} )
      ? ( $row->{last_id} + 1 )
      : 1;
}

# serialize the instance and save it with the mapper defined
sub save {
    my ($self) = @_;
    my $class  = ref $self;
    my $dbh    = $class->dbh;

    confess "Cannot save without a mapping defined for class " . ref $self
      unless defined $dbh;

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
        $self->_lock_write;
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
          or confess "Unable to execute query : \"$sql\" with "
          . join( ", ", @values ) . " : $!";
        $self->_unlock;
    }

    # if subobjects defined, save them
    if ($self->{_subobjects}) {
        foreach my $obj (@{$self->{_subobjects}}) {
            $obj->save;
        }
        delete $self->{_subobjects};
    }
    return $self->id;
}

1;
__END__

=pod

=head1 NAME

Coat::Persistent -- Simple Object-Relational mapping for Coat objects

=head1 DESCRIPTION

Coat::Persistent is an object to relational-databases mapper, it allows you to
build instance of Coat objects and save them into a databse transparently.

=head1 CONFIGURATION

=head1 SYNTAX

=head1 METHODS

=head1 SEE ALSO

=head1 AUTHOR

This module was written by Alexis Sukrieh E<lt>sukria+perl@sukria.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2007 by Alexis Sukrieh.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

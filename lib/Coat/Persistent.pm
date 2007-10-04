package Coat::Persistent;

use Coat;
use Coat::Meta;

use DBI;
use DBD::CSV;
use Carp 'confess';

use vars qw($VERSION @EXPORT $AUTHORITY);
use base qw(Exporter);

$AUTHORITY = 'cpan:SUKRIA';
$VERSION   = '0.0_0.1';
@EXPORT    = qw(has_p owns_one);

# Static method & stuff

my $MAPPINGS = {};
sub mappings { $MAPPINGS }
sub dbh { $MAPPINGS->{'!dbh'}{$_[0]} || $MAPPINGS->{'!dbh'}{'!default'} }
sub driver { $MAPPINGS->{'!driver'}{$_[1]} }

# This is the configration stuff, you basically bind a class to
# a DBI driver
sub map_to_dbi
{
    my ($class, $driver, @options) = @_;
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

    my ($table, $user, $pass) = @options;
    $driver = $drivers->{$driver};
    $MAPPINGS->{'!dbh'}{$class} = DBI->connect("${driver}:${table}", $user, $pass);
}

# The generic SQL finder, takes a SQL query and map rows returned 
# to objects of the class
sub find_by_sql
{
    my ($class, $sql, @values) = @_;

    my $dbh = $class->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values) or confess "Unable to execute query $sql";
    my $rows = $sth->fetchall_arrayref({});
    
    my @objects = map { $class->new(%$_) } @$rows;
    return wantarray 
        ? @objects
        : $objects[0];
}

# This is done to wrap the original Coat::has method so we can 
# generate finders for each attribute declared 
sub has_p {
    my ($attr, %options) = @_;

    Coat::has($attr, ('!caller' => caller, %options));

    my $class = caller;
    my $finder = sub {
        my ($class, $value) = @_;
        confess "Cannot be called from an instance" if ref $class;
        confess "Cannot find without a value" unless defined $value;

        my $table = $class->_to_sql;
        $class->find_by_sql("select * from $table where $attr = ?", $value);
    };
    my $symbol = "${class}::find_by_${attr}";
    { 
        no strict 'refs'; 
        no warnings 'redefine', 'prototype';
        *$symbol = $finder;
    }
}

sub import
{
    has_p('id' => (isa => 'Int')) ;
    Coat::_extends_class(['Coat::Persistent'], caller);
    Coat::Persistent->export_to_level( 1, @_ );
}

sub find
{
    my ($class, $id) = @_;
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
    has $foreign_key => (isa => 'Int', '!caller' => $class);

    my $symbol = "${class}::${owned_class_sql}";
    my $subobject_accessor = sub {
        my ($self, $object) = @_;

        # want to set the subobject
        if (@_ == 2) {
            if (defined $object) {
                $self->$foreign_key($object->id);
            }
            else {
                $self->$foreign_key(undef);
            }
        }

        # want to get the subobject
        else {
            return undef unless defined $self->$foreign_key;
            $owned_class->find($self->$foreign_key);
        }
    };
    {
        no strict 'refs';
        no warnings 'redefine', 'prototype';
        *$symbol = $subobject_accessor;
    }
}

# instance method & stuff

sub _to_class { 
    join '::', map { ucfirst $_ } split '_', $_[0] 
}

sub _to_sql
{
    my $table = (ref $_[0]) ? lc ref $_[0] : lc $_[0];
    $table =~ s/::/_/g;
    return $table;
}

sub _lock_write
{
    my ($self) = @_;
    return 1 if Coat::Persistent->driver( ref $self ) ne 'mysql';

    my $class = ref $self;
    my $dbh = $class->dbh;
    my $table = $self->_to_sql;
    $dbh->do("LOCK TABLE $table WRITE") 
        or confess "Unable to lock table $table";
}

sub _unlock
{
    my ($self) = @_;
    return 1 if Coat::Persistent->driver( ref $self ) ne 'mysql';

    my $class = ref $self;
    my $dbh = $class->dbh;
    $dbh->do("UNLOCK TABLES") 
        or confess "Unable to lock tables";
}

sub _next_id {
    my ($self) = @_;
    
    my $class = ref $self;
    my $dbh = $class->dbh;
    my $table = $self->_to_sql;
    
    my $sth = $dbh->prepare("select id as last_id "
                            ."from $table "
                            ."order by last_id "
                            ."desc limit 1");
    $sth->execute;
    my $row = $sth->fetchrow_hashref;
    
    return ( $row->{last_id} )
        ? ( $row->{last_id} + 1 )
        :  1 ;
}

# serialize the instance and save it with the mapper defined
sub save
{
    my ($self) = @_;  
    my $class = ref $self;
    my $dbh = $class->dbh;

    confess "Cannot save without a mapping defined for class ".ref $self 
        unless defined $dbh;
    
    my $table = $self->_to_sql;
    my @fields = keys %{ Coat::Meta->all_attributes( ref $self ) };

    my @values;

    # if we have an id, update
    if (defined $self->id) {
        my $sql = "update $table set ";
        foreach my $field (@fields) {
            next if $field eq 'id';
            $sql .= "$field=? ";
            push @values, $self->$field;
        }
        $sql .= "where id = ?";
        
        my $sth = $dbh->prepare($sql);
        $sth->execute(@values, $self->id);
    }

    # no id, insert with a valid id
    else {
        $self->_lock_write;
        $self->id( $self->_next_id );
        
        my $sql = "insert into $table ("
        . (join ", ", @fields)
        .") values ("
        . (join ", ", map { '?' } @fields)
        .")";

        foreach my $field (@fields) {
            push @values, $self->$field;
        }
    
        my $sth = $dbh->prepare($sql);
        $sth->execute(@values) 
            or confess "Unable to execute query : $sql with ".join(", ", @values);
        $self->_unlock;
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

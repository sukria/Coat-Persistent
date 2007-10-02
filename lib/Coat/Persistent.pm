package Coat::Persistent;

use Coat::Meta;

use DBI;
use DBD::CSV;
use Carp 'confess';

use vars qw($VERSION @EXPORT @ISA);
use base qw(Exporter);
$VERSION = '0.0_0.1';
@EXPORT = qw(has);

# Static method & stuff

my $MAPPINGS = {};
sub mappings { $MAPPINGS }
sub dbh { $MAPPINGS->{'!dbh'}{$_[1]} }
sub driver { $MAPPINGS->{'!driver'}{$_[1]} }

# This is the configration stuff, you basically bind a class to
# a DBI driver
sub map_to_dbi
{
    my ($class, $driver, @options) = @_;
    confess "Static method cannot be called from instance" if ref $class;

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

# This is done to wrap the original Coat::has method so we can 
# generate finders for each attribute declared 
my $has_code = sub {
    my ($attr, @options) = @_;

    my $class = caller;
    my $finder = sub {
        my ($class, $value) = @_;
        confess "Cannot be called from an instance" if ref $class;
        confess "Cannot find without a value" unless defined $value;

        my $dbh = Coat::Persistent->dbh($class);
        my $table = $class->_to_sql;

        my $sql = "select * from $table where $attr = ?";
        my $sth = $dbh->prepare($sql);
        $sth->execute($value) or confess "Unable to execute query $sql";
        my $rows = $sth->fetchall_arrayref({});
        
        # now convert each row returned to the object
        my @objects = map { $class->new(%$_) } @$rows;

        return wantarray 
            ? @objects
            : $objects[0];
    };
    my $symbol = "${class}::find_by_${attr}";
    { 
        no strict 'refs'; 
        no warnings 'redefine', 'prototype';
        *$symbol = $finder;
    }
    Coat::has($attr, @options); 
};

my $has_with_finder = "Coat::Persistent::has";
{ 
    no strict 'refs';
    no warnings 'redefine'; 
    *$has_with_finder = $has_code; 
}

sub find
{
    my ($class, $id) = @_;
    confess "Cannot be called from an instance" if ref $class;
    confess "Cannot find without an id" unless defined $id;
    $class->find_by_id($id);
}

# instance method & stuff

$has_code->('id' => ( isa => 'Int')); 

sub _to_sql
{
    my ($self) = @_;
    my $table;
    if (ref $self) {
        $table = ref $self 
    }
    else {
        $table = $self;
    }

    $table =~ s/::/__/g;
    $table;
}

sub _lock_write
{
    my ($self) = @_;
    return 1 if Coat::Persistent->driver( ref $self ) ne 'mysql';

    my $dbh = Coat::Persistent->dbh(ref $self);
    my $table = $self->_to_sql;
    $dbh->do("LOCK TABLE $table WRITE") 
        or confess "Unable to lock table $table";
}

sub _unlock
{
    my ($self) = @_;
    return 1 if Coat::Persistent->driver( ref $self ) ne 'mysql';

    my $dbh = Coat::Persistent->dbh(ref $self);
    $dbh->do("UNLOCK TABLES") 
        or confess "Unable to lock tables";
}

sub _next_id {
    my ($self) = @_;
    my $dbh = Coat::Persistent->dbh(ref $self);
    my $table = $self->_to_sql;
    
    my $sth = $dbh->prepare("select MAX(id) as last_id from $table");
    $sth->execute;
    my $row = $sth->fetchrow_hashref;
    
    return ( defined $row->{last_id} )
        ? ( $row->{last_id} + 1 )
        :  1 ;
}

# serialize the instance and save it with the mapper defined
sub save
{
    my ($self) = @_;  
    confess "Cannot save without a mapping defined for class ".ref $self 
        unless defined Coat::Persistent->dbh(ref $self);
    
    my $dbh = Coat::Persistent->dbh(ref $self);
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

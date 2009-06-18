package Coat::Persistent::Types::MySQL;

# MySQL types usable in has_p definitions 
# (either for isa or for store_as)

use strict;
use warnings;

use POSIX;
use Coat::Types;

# datetime' 

subtype 'MySQL:DateTime'
    => as 'Str'
    => where { /^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d$/ };

coerce 'MySQL:DateTime'
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
    => from 'MySQL:DateTime'
    => via {
        my ($year, $mon, $day, $hour, $min, $sec) = /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/;
        $year -= 1900;
        $mon--;
        return mktime(~~$sec, ~~$min, ~~$hour, ~~$day, $mon, $year);
    };

# date

subtype 'MySQL:Date'
    => as 'Str'
    => where { /^\d{4}-\d\d-\d\d$/ };

coerce 'MySQL:Date'
    => from 'Int'
    => via { 
        my ($sec, $min, $hour, $day, $mon, $year) = localtime($_);
        $year += 1900;
        $mon++;
        $day = sprintf('%02d', $day);
        $mon = sprintf('%02d', $mon);
        return "$year-$mon-$day";
    };

coerce 'Int'
    => from 'MySQL:Date'
    => via {
        my ($year, $mon, $day) = /^(\d{4})-(\d\d)-(\d\d)$/;
        $year -= 1900;
        $mon--;
        return mktime(0, 0, 0, int($day), int($mon), $year);
    };

1;
__END__

=pod

=head1 NAME

Coat::Persistent::Types::MySQL -- Attribute types and coercions for MySQL data types

=head1 DESCRIPTION

The types defined in this module are here to provide simple and transparent
storage of MySQL data types. This is done for atttributes you want to store 
with a different value than the one the object has.

For instance, if you have a datetime field, you may want to store it as a MySQL
"datetime" format (YYYY-MM-DD HH:MM:SS) and handle it in your code as a
timestamp, which is much more convinient for updates.

This is possible by using the types defined in this module.

=head1 EXAMPLE 

We have a 'created_at' attribute, we want to handle it as a timestamp and store
it as a MySQL datetime field.

    use Coat::Persistent::Types::MySQL;

    has_p 'created_at' => (
        is => 'rw',
        isa => 'Int', 
        store_as => 'MySQL:DateTime, 
    );

Then, whenever a value that validates the MySQL:DateTime format is assigned to
that field, it will be coerced to an Int. On the other hand, whenever an entry
has to be saved, the value used for storage will be the result of a coercion
from Int to MySQL:DateTime.

=head1 TYPES

The following types are provided by this module

=over 4 

=item MySQL:DateTime : YYYY-MM-DD HH:MM:SS

=item MySQL:Date : YYYY-MM-DD

=back

=head1 SEE ALSO

L<Coat::Types>, L<Coat::Persistent>

=head1 AUTHOR

Alexis Sukrieh <sukria@cpan.org>

=cut

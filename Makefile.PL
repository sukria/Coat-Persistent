use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => 'Coat::Persistent',
    VERSION_FROM => 'lib/Coat/Persistent.pm',
    PREREQ_PM => {
        'Coat' => '0.1_0.6',
        'DBI'  => '0',
        'DBIx::Sequence' => 0,
        'SQL::Abstract' => 0,
        'List::Compare' => 0,
    },
    ABSTRACT => "Ruby's ActiveRecord::Base port for Perl (ORM)",
    test => {TESTS => join( ' ', glob( 't/*.t' ))},
);

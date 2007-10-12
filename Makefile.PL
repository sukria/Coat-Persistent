use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => 'Coat::Persistent',
    VERSION_FROM => 'lib/Coat/Persistent.pm',
    PREREQ_PM => {
        'Coat' => '0.1_0.6',
        'DBI'  => '0',
        'DBD::CSV' => '0',
    },
    ABSTRACT => 'Simple Object-Relational Mapper for Coat',
    test => {TESTS => join( ' ', glob( 't/*.t' ))},
);

package Person;
use Coat;
use Coat::Persistent;


has_p firstname => ( isa => 'Str');
has_p lastname  => ( isa => 'Str');

1;

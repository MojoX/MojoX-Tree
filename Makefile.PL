use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
	NAME         => 'MojoX::Tree',
    VERSION_FROM => 'lib/MojoX/Tree.pm',
	AUTHOR       => 'Kostya Ten <kostya@cpan.org>',
	PREREQ_PM    => {
		'Mojolicious' => '6.10',
		'MojoX::Mysql' => '0.12',
	},
	test => {TESTS => 't/*.t'}
);

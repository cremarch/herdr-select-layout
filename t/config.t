use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Herdr::SelectLayout::Config;

my $C   = 'Herdr::SelectLayout::Config';
my $dir = tempdir(CLEANUP => 1);

sub config_file {
    my ($text) = @_;
    my $path = File::Spec->catfile($dir, 'config.toml');
    open my $fh, '>', $path or die $!;
    print {$fh} $text;
    close $fh;
    return $path;
}

subtest 'defaults' => sub {
    my $d = { main_pane_width => 80, main_pane_height => 24, main_pane => 'first', tiled => 'wide' };
    is_deeply $C->defaults, $d;
    is_deeply $C->load(undef), $d, 'no path';
    is_deeply $C->load("$dir/missing.toml"), $d, 'missing file';
    is $C->path_in($dir), File::Spec->catfile($dir, 'config.toml');
    is $C->path_in(''), undef;
};

subtest 'parses values over the defaults' => sub {
    my $c = $C->load(config_file(<<'EOF'));
# comment
main_pane_width = "60%"   # trailing comment
main_pane_height=30
main_pane = "focused"

tiled = "tall"
EOF
    is_deeply $c, { main_pane_width => '60%', main_pane_height => 30, main_pane => 'focused', tiled => 'tall' };

    is $C->load(config_file("main_pane = \"first\"\n"))->{main_pane_width}, 80, 'unset keys keep defaults';
};

subtest 'rejects what it does not understand' => sub {
    for my $case (
        [ "colour = 1\n",               qr/:1: unknown setting colour/ ],
        [ "\nmain_pane = \"last\"\n",   qr/:2: invalid value for main_pane/ ],
        [ "tiled = wide\n",             qr/invalid value for tiled/, 'unquoted string' ],
        [ "main_pane_width = 0\n",      qr/invalid value/ ],
        [ "main_pane_width = \"120%\"\n", qr/invalid value/ ],
        [ "main_pane_width = -3\n",     qr/invalid value/ ],
        [ "[section]\n",                qr/expected key = value/ ],
    ) {
        my ($text, $error, $name) = @$case;
        eval { $C->load(config_file($text)) };
        like $@, $error, $name // $text =~ s/\n/ /gr;
    }
};

subtest 'size_ratio' => sub {
    is $C->size_ratio(80, 200),    0.4;
    is $C->size_ratio('60%', 200), 0.6;
    is $C->size_ratio(500, 200),   0.95, 'clamped high';
    is $C->size_ratio(2, 200),     0.05, 'clamped low';
    is $C->size_ratio(80, undef),  0.5,  'unknown size';
};

done_testing;

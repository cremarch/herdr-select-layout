use strict;
use warnings;
use Test::More;
use Herdr::SelectLayout::Layout qw(
    LAYOUTS is_layout pane_ids grid arrange plan_moves shape spread ratio_updates
    current_layout next_layout
);

sub pane { return { type => 'pane', pane_id => $_[0] } }
sub sp   { my ($d, $a, $b, $r) = @_; return { type => 'split', direction => $d, ratio => $r // 0.5, first => $a, second => $b } }
sub rows { my ($g) = @_; return join ' / ', map { join ' ', @$_ } @$g }
sub ratios { return [ map { sprintf '%.4f', $_->{ratio} } ratio_updates($_[0], $_[0]) ] }

# Applies plan_moves the way herdr does: the moved pane splits the target's leaf.
sub build {
    my ($want) = @_;
    my ($anchor) = pane_ids($want);
    my $root = pane($anchor);
    for my $step (plan_moves($want)) {
        my ($pane, $dir, $target) = @$step;
        my $walk;
        $walk = sub {
            my ($n) = @_;
            return $n->{pane_id} eq $target ? sp($dir, $n, pane($pane)) : $n if $n->{type} eq 'pane';
            return { %$n, first => $walk->($n->{first}), second => $walk->($n->{second}) };
        };
        $root = $walk->($root);
    }
    return $root;
}

subtest 'is_layout' => sub {
    ok is_layout($_), $_ for LAYOUTS;
    ok !is_layout($_), 'not ' . ($_ // 'undef') for 'spread', 'next', 'main-vertical-mirrored', '', undef;
};

subtest 'pane_ids is depth-first' => sub {
    is_deeply [ pane_ids(sp(right => sp(down => pane('a'), pane('b')), pane('c'))) ], [qw(a b c)];
    is_deeply [ pane_ids(pane('a')) ], ['a'];
};

subtest 'grid' => sub {
    my @p = map { "p$_" } 1 .. 7;
    is rows(grid('even-horizontal', [ @p[0 .. 3] ])), 'p1 p2 p3 p4';
    is rows(grid('even-vertical',   [ @p[0 .. 2] ])), 'p1 / p2 / p3';

    my %wide = (1 => 'p1', 2 => 'p1 p2', 3 => 'p1 p2 / p3', 4 => 'p1 p2 / p3 p4',
                5 => 'p1 p2 p3 / p4 p5', 6 => 'p1 p2 p3 / p4 p5 p6', 7 => 'p1 p2 p3 / p4 p5 p6 / p7');
    is rows(grid('tiled', [ @p[0 .. $_ - 1] ])), $wide{$_}, "tiled $_" for sort keys %wide;

    my %tall = (2 => 'p1 / p2', 3 => 'p1 p2 / p3', 5 => 'p1 p2 / p3 p4 / p5', 6 => 'p1 p2 / p3 p4 / p5 p6');
    is rows(grid('tiled', [ @p[0 .. $_ - 1] ], tiled => 'tall')), $tall{$_}, "tiled tall $_" for sort keys %tall;

    for my $n (1 .. 30) {
        my ($w, $t) = (grid('tiled', [ 1 .. $n ]), grid('tiled', [ 1 .. $n ], tiled => 'tall'));
        cmp_ok scalar @$w, '<=', scalar @{ $w->[0] }, "wide $n: rows <= cols";
        cmp_ok scalar @$t, '>=', scalar @{ $t->[0] }, "tall $n: rows >= cols";
    }
    is_deeply grid('tiled', []), [], 'no panes';
    eval { grid('main-vertical', ['a']) };
    like $@, qr/not a grid layout/;
};

subtest 'arrange' => sub {
    my @p = qw(a b c d);
    my %want = (
        'even-horizontal' => 'right(a,right(b,right(c,d)))',
        'even-vertical'   => 'down(a,down(b,down(c,d)))',
        'main-vertical'   => 'right(a,down(b,down(c,d)))',
        'main-horizontal' => 'down(a,right(b,right(c,d)))',
        'tiled'           => 'down(right(a,b),right(c,d))',
    );
    is shape(arrange($_, \@p)), $want{$_}, $_ for LAYOUTS;

    is_deeply ratios(arrange('even-horizontal', \@p)), [qw(0.2500 0.3333 0.5000)];
    is_deeply ratios(arrange('main-vertical', \@p, main_ratio => 0.6)), [qw(0.6000 0.3333 0.5000)];
    is_deeply ratios(arrange('main-horizontal', [qw(a b)])), [qw(0.5000)], 'main ratio defaults to half';
    is_deeply ratios(arrange('tiled', [qw(a b c d e)])), [qw(0.5000 0.3333 0.5000 0.5000)], '3 + 2';
    is shape(arrange('main-vertical', ['a'])), 'a';
    is arrange('tiled', []), undef;
    eval { arrange('bogus', ['a']) };
    like $@, qr/unknown layout/;
};

subtest 'plan_moves builds the arranged tree' => sub {
    for my $layout (LAYOUTS) {
        for my $n (1 .. 9) {
            my $want = arrange($layout, [ map { "p$_" } 1 .. $n ]);
            is shape(build($want)), shape($want), "$layout $n";
        }
    }
    is_deeply [ plan_moves(arrange('main-vertical', [qw(a b c)])) ],
        [ [qw(b right a)], [qw(c down b)] ];
};

subtest 'spread' => sub {
    # A perpendicular subtree counts its larger side.
    my $mixed = sp(right => pane('a'), sp(down => pane('b'), sp(right => pane('c'), pane('d'))), 0.9);
    my $even  = spread($mixed);
    is shape($even), shape($mixed), 'same arrangement';
    is_deeply ratios($even), [qw(0.3333 0.5000 0.5000)];
};

subtest 'ratio_updates pairs wanted and current ratios' => sub {
    my $want   = arrange('even-horizontal', [qw(a b c)]);
    my $actual = sp(right => pane('a'), sp(right => pane('b'), pane('c'), 0.7), 0.2);
    my @u = ratio_updates($want, $actual);
    is_deeply [ map { scalar @{ $_->{path} } } @u ], [ 0, 1 ];
    ok $u[1]{path}[0], 'second child is true';
    is_deeply [ map { $_->{current} } @u ], [ 0.2, 0.7 ];
    is_deeply [ ratio_updates(pane('a'), pane('a')) ], [];
};

subtest 'current_layout and next_layout' => sub {
    my @p = qw(a b c d);
    is current_layout(arrange($_, \@p)), $_, "current $_" for LAYOUTS;

    my @cycle = map { next_layout(arrange($_, \@p)) } LAYOUTS;
    is_deeply \@cycle, [qw(even-vertical main-horizontal main-vertical tiled even-horizontal)];

    my $other = sp(right => sp(down => pane('a'), pane('b')), sp(down => pane('c'), pane('d')));
    is current_layout($other), undef, 'unknown arrangement';
    is next_layout($other), 'even-horizontal', 'starts at the first layout';

    is current_layout(arrange('tiled', \@p, tiled => 'tall'), tiled => 'tall'), 'tiled', 'tall tiled';

    # With 2 panes several layouts share a shape: next always changes the arrangement.
    my $h = arrange('even-horizontal', [qw(a b)]);
    my $v = arrange('even-vertical',   [qw(a b)]);
    is shape(arrange(next_layout($h), [qw(a b)])), shape($v);
    is shape(arrange(next_layout($v), [qw(a b)])), shape($h);
};

done_testing;

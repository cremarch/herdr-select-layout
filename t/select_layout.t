use strict;
use warnings;
use FindBin ();
use lib "$FindBin::RealBin/lib";
use Test::More;
use JSON::PP ();
use FakeHerdr;
use Herdr::SelectLayout;
use Herdr::SelectLayout::Config;
use Herdr::SelectLayout::Layout qw(shape spread ratio_updates pane_ids);

# 2x2 built by splitting: down(right(a,b), right(c,d)).
my $SQUARE = [ down => [ right => 'a', 'b' ], [ right => 'c', 'd' ] ];

sub run_mode {
    my ($herdr, $mode, $tab, %config) = @_;
    my $c = { %{ Herdr::SelectLayout::Config->defaults }, %config };
    return Herdr::SelectLayout->new(client => $herdr, tab_id => $tab // 't1', config => $c)->run($mode);
}

sub equalized {
    my ($root) = @_;
    return !grep { abs($_->{current} - $_->{ratio}) > 1e-6 } ratio_updates(spread($root), $root);
}

sub ratios {
    my ($node) = @_;
    return () if $node->{type} ne 'split';
    return (sprintf('%.2f', $node->{ratio}), ratios($node->{first}), ratios($node->{second}));
}

for my $case (
    [ 'even-horizontal', 'right(a,right(b,right(c,d)))' ],
    [ 'even-vertical',   'down(a,down(b,down(c,d)))' ],
    [ 'tiled',           'down(right(a,b),right(c,d))' ],
) {
    my ($mode, $want) = @$case;
    subtest $mode => sub {
        my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE, focused => 'c');
        is run_mode($herdr, $mode), $mode;
        is shape($herdr->root('t1')), $want;
        ok equalized($herdr->root('t1')), 'equal sizes';
        is_deeply [ $herdr->tab_ids ], ['t1'], 'temporary tab is gone';
        is $herdr->{focused}, 'c', 'focus restored';
    };
}

subtest 'tiled with 5 panes is 3 + 2' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => [ right => 'a', [ right => 'b', [ down => 'c', [ down => 'd', 'e' ] ] ] ]);
    run_mode($herdr, 'tiled');
    is shape($herdr->root('t1')), 'down(right(a,right(b,c)),right(d,e))';
    ok equalized($herdr->root('t1'));
};

subtest 'already arranged: no moves, only ratios' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => [ right => 'a', [ right => 'b', 'c', 0.9 ], 0.1 ]);
    run_mode($herdr, 'even-horizontal');
    is scalar $herdr->calls('pane.move'), 0, 'no pane.move';
    is scalar $herdr->calls('layout.set_split_ratio'), 2;
    ok equalized($herdr->root('t1'));

    $herdr->{calls} = [];
    run_mode($herdr, 'even-horizontal');
    is scalar $herdr->calls('layout.set_split_ratio'), 0, 'equal ratios are not rewritten';
};

subtest 'spread keeps the arrangement' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => [ right => [ down => 'a', 'b', 0.8 ], 'c', 0.2 ]);
    is run_mode($herdr, 'spread'), 'spread';
    is shape($herdr->root('t1')), 'right(down(a,b),c)';
    is scalar $herdr->calls('pane.move'), 0;
    ok equalized($herdr->root('t1'));
};

subtest 'next cycles through the layouts' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE);
    is run_mode($herdr, 'next'), $_ for qw(even-horizontal even-vertical main-horizontal main-vertical tiled even-horizontal);
};

subtest 'main-vertical: first pane on the left, 80 cells wide' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE, focused => 'c');
    is run_mode($herdr, 'main-vertical'), 'main-vertical';
    is shape($herdr->root('t1')), 'right(a,down(b,down(c,d)))';
    is_deeply [ ratios($herdr->root('t1')) ], [qw(0.40 0.33 0.50)], '80 of 200 cells, the rest equal';
    is_deeply [ $herdr->tab_ids ], ['t1'];
    is $herdr->{focused}, 'c';
};

subtest 'main-horizontal: first pane on top, 24 rows high' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE);
    run_mode($herdr, 'main-horizontal');
    is shape($herdr->root('t1')), 'down(a,right(b,right(c,d)))';
    is_deeply [ ratios($herdr->root('t1')) ], [qw(0.40 0.33 0.50)], '24 of 60 rows';
};

subtest 'config: percentage, focused main pane, tall tiles' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE, focused => 'c');
    run_mode($herdr, 'main-vertical', 't1', main_pane_width => '65%', main_pane => 'focused');
    is shape($herdr->root('t1')), 'right(c,down(a,down(b,d)))', 'focused pane is the main pane';
    is( (ratios($herdr->root('t1')))[0], '0.65' );
    is $herdr->{focused}, 'c';

    $herdr = FakeHerdr->new->add_tab(t1 => [ right => 'a', [ right => 'b', 'c' ] ]);
    run_mode($herdr, 'tiled', 't1', tiled => 'tall');
    is shape($herdr->root('t1')), 'down(right(a,b),c)', '3 tall: 2 + 1';
    $herdr = FakeHerdr->new->add_tab(t1 => [ right => 'a', [ right => 'b', [ right => 'c', [ right => 'd', 'e' ] ] ] ]);
    run_mode($herdr, 'tiled', 't1', tiled => 'tall');
    is shape($herdr->root('t1')), 'down(right(a,b),down(right(c,d),e))', '5 tall: 2 + 2 + 1';
};

subtest 'zoom is turned off' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE, focused => 'b', zoomed => 1);
    run_mode($herdr, 'tiled');
    is $herdr->{zoomed}, 0;
    my ($zoom) = $herdr->calls('pane.zoom');
    is_deeply $zoom->[1], { pane_id => 'b', mode => 'off' };
};

subtest 'single pane: nothing to do' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => 'a');
    is run_mode($herdr, 'tiled'), undef;
    is_deeply [ map { $_->[0] } $herdr->calls ], ['layout.export'];
};

subtest 'only the given tab is touched' => sub {
    my $herdr = FakeHerdr->new->add_tab(t2 => [ down => 'x', 'y' ])->add_tab(t1 => $SQUARE);
    run_mode($herdr, 'even-horizontal', 't1');
    is shape($herdr->root('t2')), 'down(x,y)';
    is_deeply [ $herdr->tab_ids ], [qw(t1 t2)];
};

subtest 'failure while moving back restores every pane' => sub {
    my $moves_back = 0;
    my $herdr = FakeHerdr->new(fail => sub {
        my ($method, $p) = @_;
        return $method eq 'pane.move' && ($p->{destination}{tab_id} // '') eq 't1' && ++$moves_back == 2;
    })->add_tab(t1 => $SQUARE);

    eval { run_mode($herdr, 'even-horizontal') };
    like $@, qr/injected failure/, 'error is reported';
    is_deeply [ sort(pane_ids($herdr->root('t1'))) ], [qw(a b c d)], 'all panes back in the tab';
    is_deeply [ $herdr->tab_ids ], ['t1'], 'temporary tab is gone';
};

subtest 'failure while parking restores the parked panes' => sub {
    my $parked = 0;
    my $herdr = FakeHerdr->new(fail => sub {
        my ($method, $p) = @_;
        return $method eq 'pane.move' && ($p->{destination}{tab_id} // 'new') ne 't1' && ++$parked == 2;
    })->add_tab(t1 => $SQUARE);

    eval { run_mode($herdr, 'even-vertical') };
    like $@, qr/injected failure/;
    is_deeply [ sort(pane_ids($herdr->root('t1'))) ], [qw(a b c d)];
    is_deeply [ $herdr->tab_ids ], ['t1'];
};

subtest 'a refused move is an error, not silence' => sub {
    my $herdr = FakeHerdr->new->add_tab(t1 => $SQUARE);
    no warnings 'redefine';
    local *FakeHerdr::_m_pane_move = sub { return { move_result => { changed => JSON::PP::false, reason => 'same_tab' } } };
    eval { run_mode($herdr, 'even-horizontal') };
    like $@, qr/not moved \(same_tab\)/;
};

subtest 'invalid arguments' => sub {
    eval { Herdr::SelectLayout->new(client => FakeHerdr->new, tab_id => 't1')->run('main-vertical-mirrored') };
    like $@, qr/unknown mode/;
    eval { Herdr::SelectLayout->new(tab_id => 't1') };
    like $@, qr/client is required/;
    ok Herdr::SelectLayout::is_mode($_), $_ for qw(even-horizontal even-vertical main-horizontal main-vertical tiled next spread);
};

done_testing;

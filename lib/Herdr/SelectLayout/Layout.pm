package Herdr::SelectLayout::Layout;

# Pure functions over herdr's layout tree (the `root` of `layout.export`).
#
# A node is either { type => 'pane', pane_id => ... } or
# { type => 'split', direction => 'right'|'down', ratio => ..., first => ..., second => ... },
# where ratio is the share of the first child. A path to a split is the list of turns
# from the root: false for `first`, true for `second`.

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();
use List::Util qw(max);
use POSIX qw(ceil);

our @EXPORT_OK = qw(
    LAYOUTS is_layout pane_ids grid arrange plan_moves shape spread ratio_updates
    current_layout next_layout
);

# Cycle order of `next`, as in tmux.
use constant LAYOUTS => qw(even-horizontal even-vertical main-horizontal main-vertical tiled);

my %IS_LAYOUT = map { $_ => 1 } LAYOUTS;

sub is_layout { return $IS_LAYOUT{ $_[0] // '' } ? 1 : 0 }

# Pane ids in depth-first order, which reads top-left first.
sub pane_ids {
    my ($node) = @_;
    return $node->{pane_id} if $node->{type} eq 'pane';
    return (pane_ids($node->{first}), pane_ids($node->{second}));
}

# Rows of pane ids for the grid layouts, filled row by row.
#   even-horizontal  1 row of n
#   even-vertical    n rows of 1
#   tiled            wide (default): cols = ceil(sqrt(n)), never taller than wide
#                    tall (tiled => 'tall'): rows = ceil(sqrt(n)), never wider than tall
sub grid {
    my ($layout, $panes, %opt) = @_;
    my @panes = @$panes;
    return [] unless @panes;
    my $n    = @panes;
    my $side = ceil(sqrt $n);
    my $cols = $layout eq 'even-horizontal' ? $n
             : $layout eq 'even-vertical'   ? 1
             : $layout eq 'tiled'           ? (($opt{tiled} // 'wide') eq 'tall' ? ceil($n / $side) : $side)
             : die "not a grid layout: $layout\n";
    my @rows;
    push @rows, [ splice @panes, 0, $cols ] while @panes;
    return \@rows;
}

# The wanted tree for a layout, with the ratios it should end up with.
#   main-vertical    the first pane on the left, the others stacked on the right
#   main-horizontal  the first pane on top, the others side by side below
# $opt{main_ratio} is the main pane's share for the main-* layouts (default 0.5);
# $opt{tiled} is passed to grid.
# Every split nests in `second`, which is also the shape herdr builds from plan_moves.
sub arrange {
    my ($layout, $panes, %opt) = @_;
    die "unknown layout: $layout\n" unless is_layout($layout);
    my @leaves = map { { type => 'pane', pane_id => $_ } } @$panes;
    return undef unless @leaves;

    if ($layout =~ /^main-(vertical|horizontal)$/) {
        my ($main, @others) = @leaves;
        return $main unless @others;
        my ($along, $across) = $1 eq 'vertical' ? qw(right down) : qw(down right);
        return _split($along, $opt{main_ratio} // 0.5, $main, _chain($across, @others));
    }
    my @rows = map { _chain(right => @leaves[ $_->[0] .. $_->[1] ]) } _row_ranges(grid($layout, $panes, %opt));
    return _chain(down => @rows);
}

sub _row_ranges {
    my ($grid) = @_;
    my ($at, @ranges) = (0);
    for my $row (@$grid) {
        push @ranges, [ $at, $at + $#$row ];
        $at += @$row;
    }
    return @ranges;
}

# Equal shares along the chain: the first of n takes 1/n.
sub _chain {
    my ($direction, $first, @rest) = @_;
    return $first unless @rest;
    return _split($direction, 1 / (1 + @rest), $first, _chain($direction, @rest));
}

sub _split {
    my ($direction, $ratio, $first, $second) = @_;
    return { type => 'split', direction => $direction, ratio => $ratio, first => $first, second => $second };
}

# Moves that build $tree from its first pane alone, as [pane, split, target] in order.
# Moving a pane next to a target splits the target's leaf with the moved pane second,
# so split(d, A, B) is made by moving B's first pane next to A's first pane; A and B
# then grow from those two leaves.
sub plan_moves {
    my ($node) = @_;
    return () if $node->{type} ne 'split';
    my ($a, $b) = ((pane_ids($node->{first}))[0], (pane_ids($node->{second}))[0]);
    return ([ $b, $node->{direction}, $a ], plan_moves($node->{first}), plan_moves($node->{second}));
}

# Structure and pane order, ignoring ratios: two trees with the same shape differ only
# in split sizes.
sub shape {
    my ($node) = @_;
    return $node->{pane_id} if $node->{type} eq 'pane';
    return sprintf '%s(%s,%s)', $node->{direction}, shape($node->{first}), shape($node->{second});
}

# A copy of the tree with every pane given the same share along each split's axis.
# A subtree spans its pane count along its own axis and its larger side across it.
sub spread {
    my ($node) = @_;
    return { %$node } if $node->{type} ne 'split';
    my $first  = _span($node->{first},  $node->{direction});
    my $second = _span($node->{second}, $node->{direction});
    return _split($node->{direction}, $first / ($first + $second),
        spread($node->{first}), spread($node->{second}));
}

sub _span {
    my ($node, $axis) = @_;
    return 1 if $node->{type} ne 'split';
    my ($first, $second) = (_span($node->{first}, $axis), _span($node->{second}, $axis));
    return $node->{direction} eq $axis ? $first + $second : max($first, $second);
}

# Ratios to set on $actual so it matches $want (same shape), as
# { path => [...], ratio => wanted, current => as is }, root first.
sub ratio_updates {
    my ($want, $actual, $path) = @_;
    $path //= [];
    return () if $want->{type} ne 'split';
    return (
        { path => $path, ratio => $want->{ratio}, current => $actual->{ratio} },
        ratio_updates($want->{first},  $actual->{first},  [ @$path, JSON::PP::false ]),
        ratio_updates($want->{second}, $actual->{second}, [ @$path, JSON::PP::true ]),
    );
}

# The first layout whose arrangement the tree already has, or undef. Ratios are ignored,
# so with two panes main-vertical reads as even-horizontal.
sub current_layout {
    my ($root, %opt) = @_;
    my @panes = pane_ids($root);
    my $shape = shape($root);
    for my $layout (LAYOUTS) {
        return $layout if shape(arrange($layout, \@panes, %opt)) eq $shape;
    }
    return undef;
}

# The layout after the current one in LAYOUTS, skipping layouts that would not change
# the arrangement. Starts at the first layout when the tree matches none. %opt is
# passed to arrange.
sub next_layout {
    my ($root, %opt) = @_;
    my @panes   = pane_ids($root);
    my $current = current_layout($root, %opt);
    return (LAYOUTS)[0] unless defined $current;

    my $shape = shape($root);
    my @order = (LAYOUTS);
    my ($at)  = grep { $order[$_] eq $current } 0 .. $#order;
    for my $step (1 .. $#order) {
        my $layout = $order[ ($at + $step) % @order ];
        return $layout if shape(arrange($layout, \@panes, %opt)) ne $shape;
    }
    return $current;
}

1;

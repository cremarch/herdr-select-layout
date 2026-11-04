package Herdr::SelectLayout;

# Rearranges the panes of a herdr tab like tmux select-layout.
#
# herdr refuses to move a pane within its own tab (move_result.changed = false,
# reason "same_tab"), so every pane but the first is parked in a temporary tab and
# moved back next to its new neighbour. herdr closes the temporary tab once it is
# empty. When the tab already has the wanted arrangement, nothing is moved and only
# the split ratios are reset. If a move fails half way, the parked panes are moved
# back into the tab so that no pane is left behind in the temporary one.

use strict;
use warnings;
use JSON::PP ();
use Herdr::SelectLayout::Config ();
use Herdr::SelectLayout::Layout qw(
    is_layout pane_ids arrange plan_moves shape spread ratio_updates next_layout
);

our $VERSION = '0.1.0';

# Actions other than the layouts themselves.
my %IS_COMMAND = (spread => 1, next => 1);

# Ratios closer than this to the wanted value are left alone, to avoid needless redraws.
my $RATIO_EPSILON = 1e-3;

sub is_mode { my ($mode) = @_; return is_layout($mode) || $IS_COMMAND{ $mode // '' } ? 1 : 0 }

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        client => $args{client},
        tab_id => $args{tab_id},
        config => $args{config} // Herdr::SelectLayout::Config->defaults,
    }, $class;
    die "client is required\n" unless $self->{client};
    die "tab_id is required\n" unless $self->{tab_id};
    return $self;
}

# Applies a mode to the tab:
#   even-horizontal | even-vertical | main-horizontal | main-vertical | tiled
#                rearrange into that layout
#   next         the layout after the current one
#   spread       keep the arrangement, equalize sizes
# Returns the layout applied ('spread' for spread, undef when the tab has one pane).
sub run {
    my ($self, $mode) = @_;
    die "unknown mode: $mode\n" unless is_mode($mode);

    my $root  = $self->_export;
    my @panes = pane_ids($root);
    return undef if @panes < 2;

    my $state = $self->_call('pane.layout', { pane_id => $panes[0] })->{layout};
    my $focus = $state->{focused_pane_id};
    $self->_call('pane.zoom', { pane_id => $focus, mode => 'off' }) if $state->{zoomed} && $focus;

    my $layout = $mode eq 'next' ? next_layout($root, tiled => $self->{config}{tiled}) : $mode;
    my $want   = $layout eq 'spread' ? spread($root) : $self->_target($layout, \@panes, $focus, $state->{area});

    if (shape($root) ne shape($want)) {
        $self->_rearrange($want);
        $root = $self->_export;
        die "layout differs from the plan after moving panes\n" if shape($root) ne shape($want);
    }

    $self->_set_ratios($want, $root);
    $self->_call('pane.focus', { pane_id => $focus }) if $focus;
    return $layout;
}

sub _target {
    my ($self, $layout, $panes, $focus, $area) = @_;
    my $config = $self->{config};
    my @order  = @$panes;
    my %opt    = (tiled => $config->{tiled});

    if ($layout =~ /^main-(vertical|horizontal)$/) {
        my $vertical = $1 eq 'vertical';
        if ($config->{main_pane} eq 'focused' && defined $focus) {
            @order = ($focus, grep { $_ ne $focus } @order);
        }
        $opt{main_ratio} = Herdr::SelectLayout::Config->size_ratio(
            $vertical ? $config->{main_pane_width}  : $config->{main_pane_height},
            $vertical ? $area->{width}              : $area->{height},
        );
    }
    return arrange($layout, \@order, %opt);
}

sub _call   { my ($self, @args) = @_; return $self->{client}->request(@args) }
sub _export { my ($self) = @_; return $self->_call('layout.export', { tab_id => $self->{tab_id} })->{layout}{root} }

sub _set_ratios {
    my ($self, $want, $actual) = @_;
    for my $u (ratio_updates($want, $actual)) {
        next if defined $u->{current} && abs($u->{current} - $u->{ratio}) < $RATIO_EPSILON;
        $self->_call('layout.set_split_ratio',
            { tab_id => $self->{tab_id}, path => $u->{path}, ratio => $u->{ratio} });
    }
}

sub _rearrange {
    my ($self, $want) = @_;
    my ($anchor, @others) = pane_ids($want);

    my %parked;
    my $ok = eval {
        my $workspace = $self->_call('tab.get', { tab_id => $self->{tab_id} })->{tab}{workspace_id};
        my $stage;
        for my $pane (@others) {
            my $to = defined $stage
                ? { type => 'tab', tab_id => $stage, split => 'right' }
                : { type => 'new_tab', workspace_id => $workspace, label => 'select-layout' };
            my $moved = $self->_move($pane, $to);
            $stage //= $moved->{tab_id};
            $parked{$pane} = 1;
        }
        for my $step (plan_moves($want)) {
            my ($pane, $split, $target) = @$step;
            $self->_move_back($pane, $split, $target);
            delete $parked{$pane};
        }
        1;
    };
    return if $ok;

    my $error = $@;
    $self->_restore(grep { $parked{$_} } @others);
    die $error;
}

# Best effort: bring parked panes back to the end of the tab, keeping their order.
sub _restore {
    my ($self, @panes) = @_;
    for my $pane (@panes) {
        my @here = eval { pane_ids($self->_export) } or last;
        eval { $self->_move_back($pane, 'right', $here[-1]) };
    }
}

sub _move_back {
    my ($self, $pane, $split, $target) = @_;
    return $self->_move($pane,
        { type => 'tab', tab_id => $self->{tab_id}, split => $split, target_pane_id => $target });
}

# pane.move reports a refused move as a success with changed = false.
sub _move {
    my ($self, $pane, $destination) = @_;
    my $result = $self->_call('pane.move',
        { pane_id => $pane, destination => $destination, focus => JSON::PP::false })->{move_result};
    die "herdr pane.move $pane: not moved (" . ($result->{reason} // 'unknown reason') . ")\n"
        unless $result->{changed};
    return $result->{pane};
}

1;

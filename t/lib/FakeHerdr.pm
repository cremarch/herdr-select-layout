package FakeHerdr;

# In-memory stand-in for the herdr socket API methods the plugin uses. It keeps a
# layout tree per tab and follows herdr's observed behaviour: a move within the same
# tab is refused with changed = false, a tab whose last pane leaves is closed, and a
# pane moved next to a target splits the target's leaf with the moved pane second.

use strict;
use warnings;
use Carp qw(croak);
use JSON::PP ();

sub new {
    my ($class, %args) = @_;
    return bless {
        tabs    => {},           # tab_id => { workspace_id, root }
        focused => undef,
        zoomed  => 0,
        calls   => [],
        fail    => $args{fail},  # sub ($method, $params, $self) -> true to fail this call
        next_id => 1,
    }, $class;
}

# A tab from a nested spec: 'p1' or [ right|down => spec, spec, ratio? ].
sub add_tab {
    my ($self, $tab_id, $spec, %opt) = @_;
    $self->{tabs}{$tab_id} = { workspace_id => 'w1', root => _build($spec) };
    $self->{focused} = $opt{focused} // (_panes($self->{tabs}{$tab_id}{root}))[0];
    $self->{zoomed}  = $opt{zoomed} // 0;
    return $self;
}

sub _build {
    my ($spec) = @_;
    return { type => 'pane', pane_id => $spec } unless ref $spec;
    my ($direction, $first, $second, $ratio) = @$spec;
    return { type => 'split', direction => $direction, ratio => $ratio // 0.5,
             first => _build($first), second => _build($second) };
}

sub root    { my ($self, $tab) = @_; return $self->{tabs}{$tab} && $self->{tabs}{$tab}{root} }
sub tab_ids { my ($self) = @_; return sort keys %{ $self->{tabs} } }
sub calls   { my ($self, $method) = @_; return grep { !defined $method || $_->[0] eq $method } @{ $self->{calls} } }

sub request {
    my ($self, $method, $params) = @_;
    push @{ $self->{calls} }, [ $method, $params ];
    die "herdr $method: injected failure\n" if $self->{fail} && $self->{fail}->($method, $params, $self);

    my $handler = $self->can('_m_' . ($method =~ tr/./_/r)) or croak "FakeHerdr: unsupported method $method";
    return $self->$handler($params);
}

sub _m_layout_export {
    my ($self, $p) = @_;
    my $tab = $self->{tabs}{ $p->{tab_id} } or die "herdr layout.export: layout target not found\n";
    return { layout => { root => _clone($tab->{root}) } };
}

sub _m_pane_layout {
    my ($self, $p) = @_;
    return { layout => { focused_pane_id => $self->{focused}, zoomed => $self->{zoomed} ? JSON::PP::true : JSON::PP::false, area => { x => 0, y => 0, width => 200, height => 60 } } };
}

sub _m_pane_current { my ($self) = @_; return { pane => { pane_id => $self->{focused}, tab_id => $self->_tab_of($self->{focused}) } } }
sub _m_pane_zoom    { my ($self, $p) = @_; $self->{zoomed} = $p->{mode} eq 'on' ? 1 : 0; return {} }
sub _m_pane_focus   { my ($self, $p) = @_; $self->{focused} = $p->{pane_id}; return {} }
sub _m_notification_show { return {} }

sub _m_tab_get {
    my ($self, $p) = @_;
    my $tab = $self->{tabs}{ $p->{tab_id} } or die "herdr tab.get: tab not found\n";
    return { tab => { tab_id => $p->{tab_id}, workspace_id => $tab->{workspace_id} } };
}

sub _m_layout_set_split_ratio {
    my ($self, $p) = @_;
    my $node = $self->{tabs}{ $p->{tab_id} }{root};
    $node = $_ ? $node->{second} : $node->{first} for @{ $p->{path} };
    die "herdr layout.set_split_ratio: not a split\n" unless $node && $node->{type} eq 'split';
    $node->{ratio} = $p->{ratio};
    return {};
}

sub _m_pane_move {
    my ($self, $p) = @_;
    my $pane = $p->{pane_id};
    my $from = $self->_tab_of($pane) // die "herdr pane.move: pane not found\n";
    my $to   = $p->{destination};

    my $dest;
    if ($to->{type} eq 'new_tab') {
        $dest = 'stage' . $self->{next_id}++;
    }
    else {
        $dest = $to->{tab_id};
        die "herdr pane.move: tab not found\n" unless $self->{tabs}{$dest};
        return { move_result => { changed => JSON::PP::false, reason => 'same_tab' } } if $dest eq $from;
    }

    $self->_remove($from, $pane);
    my $leaf = { type => 'pane', pane_id => $pane };
    if ($to->{type} eq 'new_tab') {
        $self->{tabs}{$dest} = { workspace_id => $to->{workspace_id}, root => $leaf };
    }
    else {
        my $target = $to->{target_pane_id} // (_panes($self->{tabs}{$dest}{root}))[-1];
        _split_leaf(\$self->{tabs}{$dest}{root}, $target, $to->{split}, $leaf)
            or die "herdr pane.move: target pane not in tab\n";
    }
    return { move_result => { changed => JSON::PP::true, pane => { pane_id => $pane, tab_id => $dest } } };
}

sub _tab_of {
    my ($self, $pane) = @_;
    for my $tab (keys %{ $self->{tabs} }) {
        return $tab if grep { $_ eq $pane } _panes($self->{tabs}{$tab}{root});
    }
    return undef;
}

sub _remove {
    my ($self, $tab, $pane) = @_;
    my $root = $self->{tabs}{$tab}{root};
    if ($root->{type} eq 'pane') {
        delete $self->{tabs}{$tab};    # last pane left: herdr closes the tab
        return;
    }
    $self->{tabs}{$tab}{root} = _without($root, $pane);
}

sub _without {
    my ($node, $pane) = @_;
    return $node if $node->{type} eq 'pane';
    return $node->{second} if $node->{first}{type}  eq 'pane' && $node->{first}{pane_id}  eq $pane;
    return $node->{first}  if $node->{second}{type} eq 'pane' && $node->{second}{pane_id} eq $pane;
    return { %$node, first => _without($node->{first}, $pane), second => _without($node->{second}, $pane) };
}

sub _split_leaf {
    my ($ref, $target, $direction, $leaf) = @_;
    my $node = $$ref;
    if ($node->{type} eq 'pane') {
        return 0 unless $node->{pane_id} eq $target;
        $$ref = { type => 'split', direction => $direction, ratio => 0.5, first => $node, second => $leaf };
        return 1;
    }
    return _split_leaf(\$node->{first}, $target, $direction, $leaf)
        || _split_leaf(\$node->{second}, $target, $direction, $leaf);
}

sub _panes {
    my ($node) = @_;
    return $node->{pane_id} if $node->{type} eq 'pane';
    return (_panes($node->{first}), _panes($node->{second}));
}

sub _clone {
    my ($node) = @_;
    return { %$node } if $node->{type} eq 'pane';
    return { %$node, first => _clone($node->{first}), second => _clone($node->{second}) };
}

1;

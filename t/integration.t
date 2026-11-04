# Runs every mode against a live herdr in a scratch tab that is never focused and is
# closed afterwards. Opt in with HERDR_INTEGRATION=1 inside a herdr session.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Herdr::SelectLayout;
use Herdr::SelectLayout::Client;
use Herdr::SelectLayout::Layout qw(pane_ids);

plan skip_all => 'set HERDR_INTEGRATION=1 inside herdr to run' unless $ENV{HERDR_INTEGRATION};

my $herdr = Herdr::SelectLayout::Client->new;
my $workspace = $ENV{HERDR_WORKSPACE_ID}
    // $herdr->request('pane.current', {})->{pane}{workspace_id};

my $created = $herdr->request('tab.create',
    { workspace_id => $workspace, label => 'select-layout-test', focus => JSON::PP::false });
my $tab   = $created->{tab}{tab_id};
my $first = $created->{root_pane}{pane_id};
END { eval { $herdr->request('tab.close', { tab_id => $tab }) } if $tab }

sub split_pane {
    my ($pane, $direction) = @_;
    return $herdr->request('pane.split',
        { target_pane_id => $pane, direction => $direction, focus => JSON::PP::false })->{pane}{pane_id};
}

# Cells per row, top to bottom: "2 2" is two rows of two panes.
sub rows_of_panes {
    my $rects = $herdr->request('pane.layout', { pane_id => $first })->{layout}{panes};
    my %row;
    $row{ $_->{rect}{y} }++ for @$rects;
    return join ' ', map { $row{$_} } sort { $a <=> $b } keys %row;
}

sub widths_even {
    my $rects = $herdr->request('pane.layout', { pane_id => $first })->{layout}{panes};
    my %by_row;
    push @{ $by_row{ $_->{rect}{y} } }, $_->{rect}{width} for @$rects;
    for my $w (values %by_row) {
        my ($min, $max) = (sort { $a <=> $b } @$w)[ 0, -1 ];
        return 0 if $max - $min > 1;
    }
    return 1;
}

my $b = split_pane($first, 'down');
split_pane($first, 'right');
split_pane($b, 'right');
$herdr->request('pane.send_text', { pane_id => $b, text => "echo select-layout-marker\n" });

my $run = sub { Herdr::SelectLayout->new(client => $herdr, tab_id => $tab)->run(@_) };

$run->('even-horizontal');
is rows_of_panes(), '4', 'even-horizontal: one row';
ok widths_even(), 'equal widths';

$run->('even-vertical');
is rows_of_panes(), '1 1 1 1', 'even-vertical: one column';

$run->('tiled');
is rows_of_panes(), '2 2', 'tiled: 2 x 2';

split_pane($first, 'down');
$run->('tiled');
is rows_of_panes(), '3 2', 'tiled with 5: 3 + 2';
ok widths_even(), 'equal widths per row';

is $run->('next'), 'even-horizontal', 'next after tiled';
is rows_of_panes(), '5';

$run->('main-vertical');
my $layout = $herdr->request('pane.layout', { pane_id => $first })->{layout};
my ($main) = grep { $_->{rect}{x} == 0 } @{ $layout->{panes} };
is scalar(grep { $_->{rect}{x} == 0 } @{ $layout->{panes} }), 1, 'main-vertical: one pane on the left';
cmp_ok abs($main->{rect}{width} - 80), '<=', 2, 'main pane is 80 cells wide';
is $main->{rect}{height}, $layout->{area}{height}, 'main pane is full height';

$run->('main-horizontal');
is rows_of_panes(), '1 4', 'main-horizontal: one on top, four below';

my @labels = map { $_->{label} // q() } @{ $herdr->request('tab.list', { workspace_id => $workspace })->{tabs} };
ok !grep({ $_ eq q(select-layout) } @labels), q(no temporary tab left);
my @panes = pane_ids($herdr->request('layout.export', { tab_id => $tab })->{layout}{root});
is scalar @panes, 5, q(no pane lost);

my $text = $herdr->request('pane.read', { pane_id => $b, source => q(recent) })->{read}{text} // '';
like $text, qr/select-layout-marker/, 'pane kept its scrollback';

done_testing;

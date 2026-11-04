package Herdr::SelectLayout::Config;

# Settings from $HERDR_PLUGIN_CONFIG_DIR/config.toml. Only flat `key = value` lines
# are read (a subset of TOML): integers, quoted strings and # comments.
#
#   main_pane_width  = 80       # main-vertical: cells, or a percentage such as "60%"
#   main_pane_height = 24       # main-horizontal: rows, or a percentage
#   main_pane        = "first"  # "first" (top-left, as tmux) or "focused"
#   tiled            = "wide"   # "wide": never taller than wide; "tall": the reverse

use strict;
use warnings;
use File::Spec ();

my %DEFAULTS = (
    main_pane_width  => 80,
    main_pane_height => 24,
    main_pane        => 'first',
    tiled            => 'wide',
);

my %VALID = (
    main_pane_width  => \&_size,
    main_pane_height => \&_size,
    main_pane        => sub { $_[0] =~ /^(first|focused)$/ ? $_[0] : undef },
    tiled            => sub { $_[0] =~ /^(wide|tall)$/     ? $_[0] : undef },
);

sub defaults { return {%DEFAULTS} }

# The settings in $path merged over the defaults; a missing file gives the defaults.
# Dies with the file and line on anything it does not understand.
sub load {
    my ($class, $path) = @_;
    my %config = %DEFAULTS;
    return \%config unless defined $path && -e $path;

    open my $fh, '<', $path or die "cannot read $path: $!\n";
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        $line =~ s/\s+#.*$// unless $line =~ /^"[^"]*#/;
        next if $line eq '' || $line =~ /^#/;

        my ($key, $raw) = $line =~ /^([a-z_]+)\s*=\s*(.+)$/
            or die "$path:$.: expected key = value\n";
        my $check = $VALID{$key} or die "$path:$.: unknown setting $key\n";
        my $value = $raw =~ /^"(.*)"$/ ? $1 : $raw =~ /^-?\d+$/ ? $raw : undef;
        $value = $check->($value) if defined $value;
        die "$path:$.: invalid value for $key: $raw\n" unless defined $value;
        $config{$key} = $value;
    }
    return \%config;
}

sub path_in {
    my ($class, $dir) = @_;
    return defined $dir && length $dir ? File::Spec->catfile($dir, 'config.toml') : undef;
}

# A main pane size as a share of $total cells: "60%" or a cell count. Kept within
# 5%..95% so that neither side disappears.
sub size_ratio {
    my ($class, $size, $total) = @_;
    my $ratio = $size =~ /^(\d+)%$/ ? $1 / 100 : $total ? $size / $total : 0.5;
    return $ratio < 0.05 ? 0.05 : $ratio > 0.95 ? 0.95 : $ratio;
}

sub _size {
    my ($v) = @_;
    return undef unless defined $v;
    return $v if $v =~ /^[1-9]\d*$/;
    return $v if $v =~ /^(\d+)%$/ && $1 >= 1 && $1 <= 99;
    return undef;
}

1;

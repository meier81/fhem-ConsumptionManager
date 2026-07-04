package ConsumptionManager::Utils;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    cm_log
    cm_debug
    cm_round
    cm_timestamp
    cm_dateKeys
    cm_now
    cm_today
    cm_month
    cm_year
    cm_isNumber
    cm_trim
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

our $VERSION = '0.1.0';

=pod

=head1 NAME

ConsumptionManager::Utils - Utility-Funktionen für das ConsumptionManager FHEM-Modul

=head1 SYNOPSIS

    use ConsumptionManager::Utils qw(:all);

    cm_log($hash, 'info', 'Nachricht');
    cm_debug($hash, 'Debug-Ausgabe');
    my $rounded = cm_round(12.3456, 2);
    my $now = cm_timestamp();

=head1 DESCRIPTION

Dieses Modul stellt kleine Hilfsfunktionen zur Verfügung, die in FHEM-Modulen
verwendet werden können. Es verwendet ausschließlich Perl Core Module und ist
für den produktiven Einsatz geeignet.

=head1 FUNCTIONS

=over 4

=item cm_log($hash, $level, $msg)

Schreibt eine Nachricht über die FHEM-Funktion C<Log3> ins Log. Das Hash-Referenz
ist das typische FHEM-Geräte-Hash und C<$level> entspricht FHEM-Log-Leveln wie
C<info>, C<warning>, C<error> oder C<debug>.

=item cm_debug($hash, $msg)

Schreibt nur dann ins Log, wenn C<$hash->{helper}{debug}> gesetzt ist.

=item cm_round($value, $digits)

Rundet eine Zahl auf die angegebene Anzahl an Nachkommastellen. C<$digits> kann
negativ sein, um an Zehnerstellen zu runden. Gibt C<undef> zurück, wenn der
Wert keine Zahl ist.

=item cm_timestamp()

Gibt einen Zeitstempel im Format C<YYYY-MM-DD HH:MM:SS> zurück.

=item cm_today()

Gibt das heutige Datum im Format C<YYYY-MM-DD> zurück.

=item cm_month()

Gibt das aktuelle Jahr und den Monat im Format C<YYYY-MM> zurück.

=item cm_year()

Gibt das aktuelle Jahr im Format C<YYYY> zurück.

=item cm_isNumber($value)

Gibt 1 zurück, wenn der Wert wie eine Zahl aussieht, ansonsten 0.

=item cm_trim($text)

Entfernt führende und nachfolgende Leerzeichen aus dem Text.

=back

=cut

sub cm_log {
    my ($hash, $level, $msg) = @_;

    return unless defined $hash;
    $level = defined $level ? $level : 'info';
    $msg   = defined $msg   ? $msg   : '';

    if (defined &Log3) {
        Log3($hash, $level, $msg);
    }
    else {
        warn "Log3 not available: [$level] $msg\n";
    }
}

sub cm_debug {
    my ($hash, $msg) = @_;

    return unless defined $hash;
    return unless $hash->{helper} && $hash->{helper}{debug};

    cm_log($hash, 'debug', $msg);
}

sub cm_round {
    my ($value, $digits) = @_;

    return undef unless defined $value;
    return undef unless cm_isNumber($value);

    $digits = 0 unless defined $digits;
    $digits = int($digits);

    if ($digits >= 0) {
        my $factor = 10**$digits;
        return sprintf("%.${digits}f", int($value * $factor + ($value <=> 0) * 0.5) / $factor);
    }

    my $factor = 10**(-$digits);
    return sprintf("%.0f", int($value / $factor + ($value <=> 0) * 0.5) * $factor);
}

sub cm_timestamp {
    my @lt = localtime();
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $lt[5] + 1900,
        $lt[4] + 1,
        $lt[3],
        $lt[2],
        $lt[1],
        $lt[0],
    );
}

###############################################################################
# Return current date keys
###############################################################################

sub cm_dateKeys {

    my ($sec, $min, $hour, $mday, $mon, $year) = localtime();

    my $day = sprintf(
        "%04d-%02d-%02d",
        $year + 1900,
        $mon + 1,
        $mday
    );

    my $month = sprintf(
        "%04d-%02d",
        $year + 1900,
        $mon + 1
    );

    my $yearKey = sprintf(
        "%04d",
        $year + 1900
    );

    return ($day, $month, $yearKey);
}

###############################################################################
# Return current unix timestamp
###############################################################################

sub cm_now {

    return time();
}

sub cm_today {
    my @lt = localtime();
    return sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
}

sub cm_month {
    my @lt = localtime();
    return sprintf('%04d-%02d', $lt[5] + 1900, $lt[4] + 1);
}

sub cm_year {
    my @lt = localtime();
    return sprintf('%04d', $lt[5] + 1900);
}

sub cm_isNumber {
    my ($value) = @_;

    return 0 unless defined $value;
    return 1 if $value =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
    return 0;
}

sub cm_trim {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

1;

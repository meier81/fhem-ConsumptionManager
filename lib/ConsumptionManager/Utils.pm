package ConsumptionManager::Utils;

use strict;
use warnings;
use Time::Local;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

our @EXPORT_OK = qw(
    cm_timestamp
    cm_dateKeys
    cm_now
    cm_today
    cm_month
    cm_year
    cm_dateCompare
    cm_dateAddDay
    cm_dateSubtractDay
    cm_dateDiffDays
);

our $VERSION = CM_VERSION;

=pod

=head1 NAME

ConsumptionManager::Utils - Shared date and time helpers.

=head1 DESCRIPTION

Small, project-wide helpers used by the ConsumptionManager modules.

=cut

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
    my (undef, $month) = cm_dateKeys();
    return $month;
}

sub cm_year {
    my @lt = localtime();
    return sprintf('%04d', $lt[5] + 1900);
}

###############################################################################
# Convert YYYY-MM-DD to unix timestamp
###############################################################################

sub _cm_dateToEpoch {

    my ($date) = @_;

    return undef
        unless defined $date;

    return undef
        unless $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;

    my ($year, $month, $day) = ($1 + 0, $2 + 0, $3 + 0);

    my $epoch = eval {
        timelocal(
            0,
            0,
            12,
            $day,
            $month - 1,
            $year
        );
    };

    return undef if $@ || !defined $epoch;

    my @lt = localtime($epoch);

    return undef
        unless $lt[5] + 1900 == $year
        && $lt[4] + 1 == $month
        && $lt[3] == $day;

    return $epoch;
}

###############################################################################
# Compare two dates
###############################################################################

sub cm_dateCompare {

    my ($date1, $date2) = @_;

    my $t1 = _cm_dateToEpoch($date1);
    my $t2 = _cm_dateToEpoch($date2);

    return undef
        unless defined $t1;
    return undef
        unless defined $t2;

    return $t1 <=> $t2;
}

###############################################################################
# Add days to date
###############################################################################

sub cm_dateAddDay {

    my ($date, $days) = @_;

    $days = 1 unless defined $days;

    my $epoch = _cm_dateToEpoch($date);

    return undef unless defined $epoch;

    $epoch += ($days * 86400);

    my @lt = localtime($epoch);

    return sprintf(
        "%04d-%02d-%02d",
        $lt[5] + 1900,
        $lt[4] + 1,
        $lt[3]
    );
}

###############################################################################
# Subtract days from date
###############################################################################


###############################################################################
# Difference between two dates in days
###############################################################################

sub cm_dateDiffDays {
    my ($date1, $date2) = @_;

    my $t1 = _cm_dateToEpoch($date1);
    my $t2 = _cm_dateToEpoch($date2);

    return undef unless defined $t1 && defined $t2;

    return int(($t2 - $t1) / 86400);
}

sub cm_dateSubtractDay {

    my ($date, $days) = @_;

    $days = 1 unless defined $days;

    return cm_dateAddDay(
        $date,
        -$days
    );
}

1;

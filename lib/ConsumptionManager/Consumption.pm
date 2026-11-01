package ConsumptionManager::Consumption;

use strict;
use warnings;
use Exporter 'import';
use Time::Local qw(timelocal);
use ConsumptionManager::Constants qw(CM_VERSION);
use ConsumptionManager::Utils qw(cm_dateKeys);
use ConsumptionManager::CounterHistory qw(
    cm_counterHistoryCalculateCurrent cm_counterHistoryCalculateRange
);

our @EXPORT_OK = qw(
    cm_consumptionToday cm_consumptionYesterday
    cm_consumptionMonth cm_consumptionLastMonth
    cm_consumptionYear cm_consumptionLastYear
    cm_consumptionPhysicalPeriod
);
our $VERSION = CM_VERSION;

# Calendar arithmetic in local time, without virtual meter baselines.
sub _previousDay {
    my ($date) = @_;
    return undef unless defined($date)
        && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my $epoch = eval { timelocal(0, 0, 12, $3, $2 - 1, $1 - 1900) };
    return undef if $@;
    my @t = localtime($epoch - 86400);
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

sub _usage {
    my ($data, $start, $end) = @_;
    return undef unless ref($data) eq 'HASH' && defined($start);
    my $result = defined($end)
        ? cm_counterHistoryCalculateRange($data, $start, $end)
        : cm_counterHistoryCalculateCurrent($data, $start);
    return ref($result) eq 'HASH' ? $result->{consumption} : undef;
}

sub cm_consumptionToday {
    my ($data) = @_;
    my ($day) = cm_dateKeys();
    return _usage($data, $day);
}

sub cm_consumptionYesterday {
    my ($data) = @_;
    my ($day) = cm_dateKeys();
    return _usage($data, _previousDay($day), $day);
}

sub cm_consumptionMonth {
    my ($data) = @_;
    my (undef, $month) = cm_dateKeys();
    return _usage($data, "$month-01");
}

sub cm_consumptionLastMonth {
    my ($data) = @_;
    my (undef, $month) = cm_dateKeys();
    my $end = "$month-01";
    my $previous = _previousDay($end);
    return _usage($data, defined($previous) ? substr($previous, 0, 7) . '-01' : undef, $end);
}

sub cm_consumptionYear {
    my ($data) = @_;
    my (undef, undef, $year) = cm_dateKeys();
    return _usage($data, "$year-01-01");
}

sub cm_consumptionLastYear {
    my ($data) = @_;
    my (undef, undef, $year) = cm_dateKeys();
    return _usage($data, ($year - 1) . '-01-01', "$year-01-01");
}

sub cm_consumptionPhysicalPeriod {
    my ($data, $period, $endDate) = @_;
    my ($day, $month, $year) = cm_dateKeys();
    my %starts = (
        today => $day,
        month => "$month-01",
        year => "$year-01-01",
    );
    return undef unless exists $starts{$period};
    return _usage($data, $starts{$period}, $endDate);
}

1;

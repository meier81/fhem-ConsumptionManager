package ConsumptionManager::Cost;

use strict;
use warnings;
use Exporter 'import';
use Time::Local qw(timelocal);
use ConsumptionManager::Constants qw(CM_VERSION);
use ConsumptionManager::Utils qw(cm_dateKeys);
use ConsumptionManager::Billing qw(cm_billingCalculatePhysicalPeriod);

our @EXPORT_OK = qw(
    cm_costToday cm_costYesterday cm_costMonth
    cm_costLastMonth cm_costYear cm_costLastYear
);
our $VERSION = CM_VERSION;

# Compatibility API: costs must always use dated physical meter and tariff
# segments. The optional legacy tariff argument is intentionally ignored.
sub _previousDay {
    my ($date) = @_;
    return undef unless defined($date)
        && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my $epoch = eval { timelocal(0, 0, 12, $3, $2 - 1, $1 - 1900) };
    return undef if $@;
    my @t = localtime($epoch - 86400);
    return sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);
}

sub _calculate {
    my ($data, $from, $to) = @_;
    return undef unless defined $from;
    my $result = cm_billingCalculatePhysicalPeriod($data, $from, $to);
    return undef unless ref($result) eq 'HASH'
        && ($result->{status} // '') eq 'active';
    return { total => $result->{totalCost},
        work => $result->{workCost}, base => $result->{baseCost},
        surface => $result->{surfaceCost},
        billingConsumption => $result->{billingConsumption} };
}

sub cm_costToday {
    my ($data) = @_;
    my ($day) = cm_dateKeys();
    return _calculate($data, $day);
}
sub cm_costYesterday {
    my ($data) = @_;
    my ($day) = cm_dateKeys();
    return _calculate($data, _previousDay($day), $day);
}
sub cm_costMonth {
    my ($data) = @_;
    my (undef, $month) = cm_dateKeys();
    return _calculate($data, "$month-01");
}
sub cm_costLastMonth {
    my ($data) = @_;
    my (undef, $month) = cm_dateKeys();
    my $end = "$month-01";
    my $prev = _previousDay($end);
    return _calculate($data,
        defined($prev) ? substr($prev, 0, 7) . '-01' : undef, $end);
}
sub cm_costYear {
    my ($data) = @_;
    my (undef, undef, $year) = cm_dateKeys();
    return _calculate($data, "$year-01-01");
}
sub cm_costLastYear {
    my ($data) = @_;
    my (undef, undef, $year) = cm_dateKeys();
    return _calculate($data, ($year - 1) . '-01-01', "$year-01-01");
}

1;

package ConsumptionManager::Cost;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionYesterday
    cm_consumptionMonth
    cm_consumptionLastMonth
    cm_consumptionYear
    cm_consumptionLastYear
);

use ConsumptionManager::Tariff qw(
    cm_tariffConvert
);

our @EXPORT_OK = qw(
    cm_costToday
    cm_costYesterday
    cm_costMonth
    cm_costLastMonth
    cm_costYear
    cm_costLastYear
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Cost

=head1 DESCRIPTION

Cost calculation for work price and prorated base price.

=cut

###############################################################################
# Calculate work cost
###############################################################################

sub cm_costCalculateWork {
    my ($consumption, $tariff) = @_;

    return undef unless _cm_costValidNumber($consumption);
    return undef unless ref($tariff) eq 'HASH';
    return undef unless _cm_costValidNumber($tariff->{workPrice});

    my $billingConsumption = cm_tariffConvert($consumption, $tariff);

    return $billingConsumption * $tariff->{workPrice};
}

###############################################################################
# Calculate prorated base cost for a number of days
###############################################################################

sub cm_costCalculateBase {
    my ($tariff, $days) = @_;

    return undef unless ref($tariff) eq 'HASH';
    return undef unless _cm_costValidNumber($tariff->{basePrice});
    return undef unless _cm_costValidNumber($days);
    return undef if $days < 0;

    my $unit = $tariff->{basePriceUnit} // '';
    my $dailyPrice;

    if ($unit eq 'month') {
        $dailyPrice = ($tariff->{basePrice} * 12) / 365;
    }
    elsif ($unit eq 'year') {
        $dailyPrice = $tariff->{basePrice} / 365;
    }
    else {
        return undef;
    }

    return $dailyPrice * $days;
}

###############################################################################
# Calculate prorated wastewater surface costs (EUR/m2/year)
###############################################################################

sub _cm_costCalculateAnnualArea {
    my ($area, $price, $days) = @_;

    return undef unless _cm_costValidNumber($area);
    return undef unless _cm_costValidNumber($price);
    return undef unless _cm_costValidNumber($days);
    return undef if $days < 0;

    return (($area * $price) / 365) * $days;
}

sub cm_costCalculateSurfaceUsage {
    my ($tariff, $days) = @_;
    return undef unless ref($tariff) eq 'HASH';

    return _cm_costCalculateAnnualArea(
        $tariff->{surfaceUsageArea} // 0,
        $tariff->{surfaceUsagePrice} // 0,
        $days
    );
}

sub cm_costCalculateSurfaceRecurring {
    my ($tariff, $days) = @_;
    return undef unless ref($tariff) eq 'HASH';

    return _cm_costCalculateAnnualArea(
        $tariff->{surfaceRecurringArea} // 0,
        $tariff->{surfaceRecurringPrice} // 0,
        $days
    );
}

###############################################################################
# Calculate billing consumption, work cost, base cost and total cost
###############################################################################

sub cm_costCalculate {
    my ($consumption, $tariff, $days) = @_;

    my $work = cm_costCalculateWork($consumption, $tariff);
    my $base = cm_costCalculateBase($tariff, $days);
    my $surfaceUsage = cm_costCalculateSurfaceUsage($tariff, $days);
    my $surfaceRecurring = cm_costCalculateSurfaceRecurring($tariff, $days);

    return undef unless defined $work;
    return undef unless defined $base;
    return undef unless defined $surfaceUsage;
    return undef unless defined $surfaceRecurring;

    my $surface = $surfaceUsage + $surfaceRecurring;

    return {
        billingConsumption => cm_tariffConvert($consumption, $tariff),
        work               => $work,
        base               => $base,
        surfaceUsage       => $surfaceUsage,
        surfaceRecurring   => $surfaceRecurring,
        surface            => $surface,
        total              => $work + $base + $surface,
    };
}

sub cm_costToday {
    my ($data, $tariff) = @_;
    return cm_costCalculate(cm_consumptionToday($data), $tariff, 1);
}

sub cm_costYesterday {
    my ($data, $tariff) = @_;
    return cm_costCalculate(cm_consumptionYesterday($data), $tariff, 1);
}

sub cm_costMonth {
    my ($data, $tariff) = @_;
    return cm_costCalculate(cm_consumptionMonth($data), $tariff, _cm_daysElapsedInMonth());
}

sub cm_costLastMonth {
    my ($data, $tariff) = @_;
    return cm_costCalculate(cm_consumptionLastMonth($data), $tariff, _cm_daysInPreviousMonth());
}

sub cm_costYear {
    my ($data, $tariff) = @_;
    return cm_costCalculate(cm_consumptionYear($data), $tariff, _cm_daysElapsedInYear());
}

sub cm_costLastYear {
    my ($data, $tariff) = @_;
    return cm_costCalculate(cm_consumptionLastYear($data), $tariff, _cm_daysInPreviousYear());
}

sub _cm_costValidNumber {
    my ($value) = @_;
    return defined($value) && $value =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub _cm_isLeapYear {
    my ($year) = @_;
    return (($year % 4 == 0 && $year % 100 != 0) || $year % 400 == 0) ? 1 : 0;
}

sub _cm_daysElapsedInMonth {
    my @lt = localtime();
    return $lt[3];
}

sub _cm_daysElapsedInYear {
    my @lt = localtime();
    return $lt[7] + 1;
}

sub _cm_daysInPreviousYear {
    my @lt = localtime();
    my $year = $lt[5] + 1900 - 1;
    return _cm_isLeapYear($year) ? 366 : 365;
}

sub _cm_daysInPreviousMonth {
    my @lt = localtime();
    my $year  = $lt[5] + 1900;
    my $month = $lt[4];

    if ($month == 0) {
        $month = 12;
        $year--;
    }

    my @days = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    $days[1] = 29 if _cm_isLeapYear($year);

    return $days[$month - 1];
}

1;

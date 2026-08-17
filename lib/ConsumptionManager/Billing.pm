package ConsumptionManager::Billing;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(CM_VERSION);
use ConsumptionManager::Utils qw(
    cm_today
    cm_dateCompare
    cm_dateSubtractDay
    cm_dateDiffDays
);
use ConsumptionManager::Tariff qw(
    cm_tariffFind
    cm_tariffConvert
);
use ConsumptionManager::Advance qw(
    cm_advanceFind
);
use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionMonth
);

our @EXPORT_OK = qw(
    cm_billingCalculate
    cm_billingCalculatePeriod
    cm_billingCalculatePreviousPeriod
    cm_billingScheduledAdvances
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Billing

=head1 DESCRIPTION

Calendar-year and current-period cost calculation for electricity, gas, water and wastewater. Tariff changes are split at their validity date using exact virtual
counter snapshots.

=cut

sub _cm_billingOffsetBeforeDate {
    my ($data, $date) = @_;
    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $date;

    my $offset = 0;
    for my $change (@{ $data->{meterChanges} // [] }) {
        next unless ref($change) eq 'HASH';
        next unless defined $change->{date};
        next unless $change->{date} lt $date;

        if (defined $change->{offsetDelta}) {
            $offset += $change->{offsetDelta};
        }
        elsif (defined $change->{oldCounter} && defined $change->{newCounter}) {
            $offset += $change->{oldCounter} - $change->{newCounter};
        }
    }
    return $offset;
}

sub _cm_billingYearBaseline {
    my ($data, $year, $currentVirtual) = @_;
    return undef unless ref($data) eq 'HASH';
    return undef unless defined $year && $year =~ /^\d{4}$/;

    my $c = $data->{consumption} // {};
    if (($c->{yearKey} // '') eq $year
        && _cm_billingNumber($c->{yearBaseline})) {
        return {
            counter => 0 + $c->{yearBaseline},
            source  => 'yearBaseline',
            exact   => 1,
        };
    }

    return undef;
}

sub cm_billingScheduledAdvances {
    my ($data, $startDate, $endDate) = @_;
    return undef unless ref($data) eq 'HASH';
    return undef unless defined cm_dateCompare($startDate, $startDate);
    return undef unless defined cm_dateCompare($endDate, $endDate);
    return undef if cm_dateCompare($endDate, $startDate) < 0;

    my ($year, $month) = $startDate =~ /^(\d{4})-(\d{2})-/;
    my ($endYear, $endMonth) = $endDate =~ /^(\d{4})-(\d{2})-/;
    return undef unless defined $year && defined $endYear;

    my ($sum, $count) = (0, 0);
    my @items;
    while ($year < $endYear || ($year == $endYear && $month <= $endMonth)) {
        my $probeDate = sprintf('%04d-%02d-01', $year, $month);
        $probeDate = $startDate if cm_dateCompare($probeDate, $startDate) < 0;

        if (cm_dateCompare($probeDate, $endDate) <= 0) {
            my $advance = cm_advanceFind($data, $probeDate);
            if (defined $advance) {
                my $amount = $advance->{amount} // 0;
                $sum += $amount;
                $count++;
                push @items, {
                    month  => sprintf('%04d-%02d', $year, $month),
                    amount => $amount,
                    id     => $advance->{id},
                };
            }
        }

        $month++;
        if ($month > 12) {
            $month = 1;
            $year++;
        }
    }

    return { amount => $sum, count => $count, items => \@items };
}

# Calculate costs for a range with known virtual start/end counters.
sub _cm_billingCalculateCostRange {
    my ($data, $startDate, $endDate, $startCounter, $endCounter, $startExact) = @_;
    return undef unless ref($data) eq 'HASH';
    return undef unless _cm_billingNumber($startCounter);
    return undef unless _cm_billingNumber($endCounter);
    return {
        status       => 'invalidCounterRange',
        startDate    => $startDate,
        endDate      => $endDate,
        counterStart => 0 + $startCounter,
        counterEnd   => 0 + $endCounter,
    } if $endCounter < $startCounter;

    my $firstTariff = cm_tariffFind($data, $startDate);
    return { status => 'noTariff', startDate => $startDate, endDate => $endDate }
        unless defined $firstTariff;

    my @changes = sort {
        ($a->{validFrom} // '') cmp ($b->{validFrom} // '')
    } grep {
        ref($_) eq 'HASH'
        && defined($_->{validFrom})
        && $_->{validFrom} gt $startDate
        && $_->{validFrom} le $endDate
    } @{ $data->{tariffs} // [] };

    my @segments;
    my $segmentStartDate    = $startDate;
    my $segmentStartCounter = 0 + $startCounter;
    my $segmentTariff       = $firstTariff;
    my $exact               = $startExact ? 1 : 0;

    for my $tariff (@changes) {
        my $snapshot = $tariff->{counterSnapshot};
        return {
            status     => 'incomplete',
            error      => 'missingTariffSnapshot',
            tariffDate => $tariff->{validFrom},
            startDate  => $startDate,
            endDate    => $endDate,
        } unless _cm_billingNumber($snapshot);

        return {
            status     => 'incomplete',
            error      => 'inexactTariffSnapshot',
            tariffDate => $tariff->{validFrom},
            snapshotDate => $tariff->{counterSnapshotDate} // '',
            startDate  => $startDate,
            endDate    => $endDate,
        } unless $tariff->{counterSnapshotExact};

        my $segmentEndDate = cm_dateSubtractDay($tariff->{validFrom});
        my $segment = _cm_billingBuildSegment(
            $segmentTariff,
            $segmentStartDate,
            $segmentEndDate,
            $segmentStartCounter,
            $snapshot
        );
        return undef unless defined $segment;
        push @segments, $segment;

        $segmentStartDate    = $tariff->{validFrom};
        $segmentStartCounter = 0 + $snapshot;
        $segmentTariff       = $tariff;
    }

    my $last = _cm_billingBuildSegment(
        $segmentTariff,
        $segmentStartDate,
        $endDate,
        $segmentStartCounter,
        $endCounter
    );
    return undef unless defined $last;
    push @segments, $last;

    my ($counterTotal, $billingTotal, $workTotal, $baseTotal, $surfaceUsageTotal, $surfaceRecurringTotal, $costTotal) = (0, 0, 0, 0, 0, 0, 0);
    for my $segment (@segments) {
        $counterTotal          += $segment->{counterConsumption};
        $billingTotal          += $segment->{billingConsumption};
        $workTotal             += $segment->{workCost};
        $baseTotal             += $segment->{baseCost};
        $surfaceUsageTotal     += $segment->{surfaceUsageCost} // 0;
        $surfaceRecurringTotal += $segment->{surfaceRecurringCost} // 0;
        $costTotal             += $segment->{totalCost};
    }

    my $surfaceTotal = $surfaceUsageTotal + $surfaceRecurringTotal;

    return {
        status             => 'active',
        exact              => $exact,
        startDate          => $startDate,
        endDate            => $endDate,
        counterStart       => 0 + $startCounter,
        counterEnd         => 0 + $endCounter,
        counterConsumption => $counterTotal,
        billingConsumption => $billingTotal,
        workCost           => $workTotal,
        baseCost              => $baseTotal,
        surfaceUsageCost      => $surfaceUsageTotal,
        surfaceRecurringCost  => $surfaceRecurringTotal,
        surfaceCost           => $surfaceTotal,
        totalCost             => $costTotal,
        unitCounter        => $firstTariff->{unitCounter} // '',
        unitBilling        => $firstTariff->{unitBilling} // '',
        currency           => $firstTariff->{currency} // ($data->{settings}{currency} // 'EUR'),
        segments           => \@segments,
    };
}

sub _cm_billingBuildSegment {
    my ($tariff, $startDate, $endDate, $startCounter, $endCounter) = @_;
    return undef unless ref($tariff) eq 'HASH';
    return undef if $endCounter < $startCounter;

    my $days = cm_dateDiffDays($startDate, $endDate);
    return undef unless defined $days;
    $days++;

    my $counterConsumption = $endCounter - $startCounter;
    my $billingConsumption = cm_tariffConvert($counterConsumption, $tariff);
    return undef unless defined $billingConsumption;

    my $work = $billingConsumption * ($tariff->{workPrice} // 0);
    my $base = _cm_billingBaseForDays($tariff, $days, $startDate);
    return undef unless defined $base;

    my $surfaceUsage = _cm_billingAnnualAreaForDays(
        $tariff->{surfaceUsageArea} // 0,
        $tariff->{surfaceUsagePrice} // 0,
        $days,
        $startDate
    );
    return undef unless defined $surfaceUsage;

    my $surfaceRecurring = _cm_billingAnnualAreaForDays(
        $tariff->{surfaceRecurringArea} // 0,
        $tariff->{surfaceRecurringPrice} // 0,
        $days,
        $startDate
    );
    return undef unless defined $surfaceRecurring;

    my $surface = $surfaceUsage + $surfaceRecurring;

    return {
        startDate          => $startDate,
        endDate            => $endDate,
        days               => $days,
        counterStart       => 0 + $startCounter,
        counterEnd         => 0 + $endCounter,
        counterConsumption => $counterConsumption,
        billingConsumption => $billingConsumption,
        workCost           => $work,
        baseCost              => $base,
        surfaceUsageCost      => $surfaceUsage,
        surfaceRecurringCost  => $surfaceRecurring,
        surfaceCost           => $surface,
        totalCost             => $work + $base + $surface,
        tariffId           => $tariff->{id},
        workPrice          => $tariff->{workPrice} // 0,
        basePrice          => $tariff->{basePrice} // 0,
        basePriceUnit      => $tariff->{basePriceUnit} // '',
        calorificValue     => $tariff->{calorificValue} // 1,
        stateNumber        => $tariff->{stateNumber} // 1,
        assessmentFactor       => $tariff->{assessmentFactor} // 1,
        surfaceUsageArea       => $tariff->{surfaceUsageArea} // 0,
        surfaceUsagePrice      => $tariff->{surfaceUsagePrice} // 0,
        surfaceRecurringArea   => $tariff->{surfaceRecurringArea} // 0,
        surfaceRecurringPrice  => $tariff->{surfaceRecurringPrice} // 0,
    };
}

# Current day/month/year cost calculation. Day and month use the exact current
# aggregate to infer the virtual start counter. Year uses the yearly baseline.
sub cm_billingCalculatePeriod {
    my ($data, $period, $asOfDate) = @_;
    return undef unless ref($data) eq 'HASH';
    $asOfDate = cm_today() unless defined $asOfDate && $asOfDate ne '';
    return undef unless defined cm_dateCompare($asOfDate, $asOfDate);

    return cm_billingCalculate($data, $asOfDate) if ($period // '') eq 'year';

    return { status => 'noCounter' }
        unless _cm_billingNumber($data->{meter}{current});

    my $currentVirtual = $data->{meter}{virtual};
    $currentVirtual = $data->{meter}{current}
        unless _cm_billingNumber($currentVirtual);

    my ($year, $month) = $asOfDate =~ /^(\d{4})-(\d{2})-/;
    my ($startDate, $consumption);

    if (($period // '') eq 'today') {
        $startDate   = $asOfDate;
        $consumption = cm_consumptionToday($data);
    }
    elsif (($period // '') eq 'month') {
        my $monthKey = "$year-$month";
        $startDate   = $monthKey . '-01';
        $consumption = cm_consumptionMonth($data);
    }
    else {
        return undef;
    }

    return undef unless _cm_billingNumber($consumption);
    my $startCounter = $currentVirtual - $consumption;
    return undef if $startCounter < 0;

    my $result = _cm_billingCalculateCostRange(
        $data,
        $startDate,
        $asOfDate,
        $startCounter,
        $currentVirtual,
        1
    );
    $result->{period} = $period if ref($result) eq 'HASH';
    return $result;
}


###############################################################################
# Calculate one completed previous period from the compact consumption state.
# No history is stored: the current period baseline is also the exact end
# counter of the immediately preceding period.
###############################################################################

sub cm_billingCalculatePreviousPeriod {
    my ($data, $period) = @_;
    return undef unless ref($data) eq 'HASH';

    my $c = $data->{consumption} // {};
    my ($startDate, $endDate, $endCounter, $counterConsumption);

    if (($period // '') eq 'yesterday') {
        return undef unless defined($c->{dayKey}) && $c->{dayKey} ne '';
        return undef unless _cm_billingNumber($c->{dayBaseline});
        return undef unless _cm_billingNumber($c->{yesterday});

        $endDate = cm_dateSubtractDay($c->{dayKey});
        return undef unless defined $endDate;
        $startDate          = $endDate;
        $endCounter         = 0 + $c->{dayBaseline};
        $counterConsumption = 0 + $c->{yesterday};
    }
    elsif (($period // '') eq 'lastMonth') {
        return undef unless defined($c->{monthKey}) && $c->{monthKey} =~ /^\d{4}-\d{2}$/;
        return undef unless _cm_billingNumber($c->{monthBaseline});
        return undef unless _cm_billingNumber($c->{lastMonthValue});

        $endDate = cm_dateSubtractDay($c->{monthKey} . '-01');
        return undef unless defined $endDate;
        my ($previousMonth) = $endDate =~ /^(\d{4}-\d{2})-/;
        return undef unless defined $previousMonth;
        $startDate          = $previousMonth . '-01';
        $endCounter         = 0 + $c->{monthBaseline};
        $counterConsumption = 0 + $c->{lastMonthValue};
    }
    elsif (($period // '') eq 'lastYear') {
        return undef unless defined($c->{yearKey}) && $c->{yearKey} =~ /^\d{4}$/;
        return undef unless _cm_billingNumber($c->{yearBaseline});
        return undef unless _cm_billingNumber($c->{lastYearValue});

        my $previousYear = (0 + $c->{yearKey}) - 1;
        $startDate          = sprintf('%04d-01-01', $previousYear);
        $endDate            = sprintf('%04d-12-31', $previousYear);
        $endCounter         = 0 + $c->{yearBaseline};
        $counterConsumption = 0 + $c->{lastYearValue};
    }
    else {
        return undef;
    }

    my $startCounter = $endCounter - $counterConsumption;
    return undef if $startCounter < 0;

    my $result = _cm_billingCalculateCostRange(
        $data,
        $startDate,
        $endDate,
        $startCounter,
        $endCounter,
        1
    );
    $result->{period} = $period if ref($result) eq 'HASH';
    return $result;
}

sub cm_billingCalculate {
    my ($data, $asOfDate) = @_;
    return undef unless ref($data) eq 'HASH';

    $asOfDate = cm_today() unless defined $asOfDate && $asOfDate ne '';
    return undef unless defined cm_dateCompare($asOfDate, $asOfDate);

    my ($year) = $asOfDate =~ /^(\d{4})-/;
    return undef unless defined $year;

    my $startDate = $year . '-01-01';
    my $endDate   = $year . '-12-31';
    my $effectiveEnd = cm_dateCompare($asOfDate, $endDate) > 0 ? $endDate : $asOfDate;

    return { status => 'noCounter', startDate => $startDate, endDate => $endDate }
        unless _cm_billingNumber($data->{meter}{current});

    my $currentVirtual = $data->{meter}{virtual};
    $currentVirtual = $data->{meter}{current}
        unless _cm_billingNumber($currentVirtual);

    my $baseline = _cm_billingYearBaseline($data, $year, $currentVirtual);
    return { status => 'noBaseline', startDate => $startDate, endDate => $endDate, year => $year }
        unless defined $baseline;

    my $cost = _cm_billingCalculateCostRange(
        $data,
        $startDate,
        $effectiveEnd,
        $baseline->{counter},
        $currentVirtual,
        $baseline->{exact}
    );
    return undef unless defined $cost;
    return $cost unless ($cost->{status} // '') eq 'active';

    my $advances = cm_billingScheduledAdvances($data, $startDate, $effectiveEnd);
    return undef unless defined $advances;

    return {
        %{$cost},
        year             => $year,
        endDate          => $endDate,
        calculatedTo     => $effectiveEnd,
        baselineCounter  => $baseline->{counter},
        baselineSource   => $baseline->{source},
        advanceAmount    => $advances->{amount},
        advanceCount     => $advances->{count},
        financialReserve => $advances->{amount} - $cost->{totalCost},
    };
}

sub _cm_billingBaseForDays {
    my ($tariff, $days, $date) = @_;
    return undef unless ref($tariff) eq 'HASH';
    return undef unless defined $days && $days >= 0;

    my $base = $tariff->{basePrice} // 0;
    my $unit = $tariff->{basePriceUnit} // '';
    my ($year) = $date =~ /^(\d{4})-/;
    my $yearDays = _cm_billingLeapYear($year) ? 366 : 365;

    return (($base * 12) / $yearDays) * $days if $unit eq 'month';
    return ($base / $yearDays) * $days if $unit eq 'year';
    return undef;
}

sub _cm_billingAnnualAreaForDays {
    my ($area, $price, $days, $date) = @_;
    return undef unless defined $days && $days >= 0;
    return undef unless _cm_billingNumber($area) && _cm_billingNumber($price);

    my ($year) = $date =~ /^(\d{4})-/;
    return undef unless defined $year;
    my $yearDays = _cm_billingLeapYear($year) ? 366 : 365;

    return (($area * $price) / $yearDays) * $days;
}

sub _cm_billingLeapYear {
    my ($year) = @_;
    return 0 unless defined $year;
    return 1 if $year % 400 == 0;
    return 0 if $year % 100 == 0;
    return $year % 4 == 0 ? 1 : 0;
}

sub _cm_billingNumber {
    my ($value) = @_;
    return defined($value) && $value =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

1;

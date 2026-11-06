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
use ConsumptionManager::CounterHistory qw(cm_counterHistoryCalculateCurrent cm_counterHistoryCalculateRange);
use ConsumptionManager::Advance qw(
    cm_advanceFind
);

our @EXPORT_OK = qw(
    cm_billingScheduledAdvances
    cm_billingCalculatePhysicalPeriod
    cm_billingCalculatePhysicalYear
    cm_billingCalculatePhysicalBillingYear
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Billing

=head1 DESCRIPTION

Calendar-year and current-period cost calculation for electricity, gas, water and wastewater. Tariff changes are split at physical midnight boundaries.

=cut

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

sub cm_billingCalculatePhysicalPeriod {
    my ($data, $startDate, $endDate) = @_;
    return undef unless ref($data) eq 'HASH'
        && defined($startDate) && $startDate =~ /^\d{4}-\d{2}-\d{2}$/;
    return undef if defined($endDate) && $endDate !~ /^\d{4}-\d{2}-\d{2}$/;
    my $physical = defined($endDate)
        ? cm_counterHistoryCalculateRange($data, $startDate, $endDate)
        : cm_counterHistoryCalculateCurrent($data, $startDate);
    return { status => 'incomplete', error => 'missingPhysicalReadings' }
        unless ref($physical) eq 'HASH';

    my $endDay = $physical->{endDate};
    my @tariffStarts = sort map { $_->{validFrom} }
        grep { ref($_) eq 'HASH'
            && defined($_->{validFrom})
            && $_->{validFrom} gt $startDate
            && (defined($endDate)
                ? $_->{validFrom} lt $endDay
                : $_->{validFrom} le $endDay)
        } @{ $data->{tariffs} // [] };
    # Two tariff definitions with the same start date would otherwise
    # produce a zero-length interval and ambiguous billing.
    for my $i (1 .. $#tariffStarts) {
        return { status => 'incomplete', error => 'duplicateTariffBoundary',
                 boundary => $tariffStarts[$i] }
            if $tariffStarts[$i] eq $tariffStarts[$i-1];
    }
    my @dates = ($startDate, @tariffStarts);
    my @results;
    my ($usage, $billed, $workTotal, $baseTotal,
        $surfaceUsageTotal, $surfaceRecurringTotal) = (0, 0, 0, 0, 0, 0);

    for my $i (0 .. $#dates) {
        my $from = $dates[$i];
        my $to = $i < $#dates ? $dates[$i+1] : undef;
        my $segment = $i == 0 && !defined($to)
            ? $physical
            : defined($to)
                ? cm_counterHistoryCalculateRange($data, $from, $to)
                : defined($endDate)
                    ? cm_counterHistoryCalculateRange($data, $from, $endDate)
                    : cm_counterHistoryCalculateCurrent($data, $from);
        return { status => 'incomplete', error => 'missingPhysicalTariffBoundary',
                 boundary => $from }
            unless ref($segment) eq 'HASH';

        my $tariff = cm_tariffFind($data, $from);
        return { status => 'noTariff', startDate => $from }
            unless ref($tariff) eq 'HASH';
        my $converted = cm_tariffConvert($segment->{consumption}, $tariff);
        return undef unless defined $converted;

        # The interval end is exclusive for a completed physical boundary.
        # For a live reading, the current calendar day is included.
        my $days = defined($to) ? cm_dateDiffDays($from, $to)
            : defined($endDate) ? cm_dateDiffDays($from, $endDate)
            : cm_dateDiffDays($from, $endDay) + 1;
        return undef unless defined($days) && $days >= 0;
        my $work = $converted * ($tariff->{workPrice} // 0);
        my $base = _cm_billingBaseForDays($tariff, $days, $from);
        my $surfaceUsage = _cm_billingAnnualAreaForDays(
            $tariff->{surfaceUsageArea} // 0,
            $tariff->{surfaceUsagePrice} // 0, $days, $from);
        my $surfaceRecurring = _cm_billingAnnualAreaForDays(
            $tariff->{surfaceRecurringArea} // 0,
            $tariff->{surfaceRecurringPrice} // 0, $days, $from);
        return undef unless defined($base)
            && defined($surfaceUsage) && defined($surfaceRecurring);

        push @results, {
            startDate => $from, endDate => $to // $endDay,
            days => $days,
            counterConsumption => $segment->{consumption},
            billingConsumption => $converted,
            workCost => $work, baseCost => $base,
            surfaceUsageCost => $surfaceUsage,
            surfaceRecurringCost => $surfaceRecurring,
            totalCost => $work + $base + $surfaceUsage + $surfaceRecurring,
            tariffId => $tariff->{id},
            physicalSegments => $segment->{segments},
        };
        $usage += $segment->{consumption};
        $billed += $converted;
        $workTotal += $work;
        $baseTotal += $base;
        $surfaceUsageTotal += $surfaceUsage;
        $surfaceRecurringTotal += $surfaceRecurring;
    }
    return {
        status => 'active', source => 'physicalReadings',
        startDate => $startDate, endDate => $endDay,
        counterConsumption => $usage,
        billingConsumption => $billed,
        workCost => $workTotal, baseCost => $baseTotal,
        surfaceUsageCost => $surfaceUsageTotal,
        surfaceRecurringCost => $surfaceRecurringTotal,
        surfaceCost => $surfaceUsageTotal + $surfaceRecurringTotal,
        totalCost => $workTotal + $baseTotal
            + $surfaceUsageTotal + $surfaceRecurringTotal,
        segments => \@results,
    };
}

# Current-year billing using physical meter readings and scheduled advances.
# A missing physical boundary is an explicit incomplete result, not zero.
sub cm_billingCalculatePhysicalYear {
    my ($data, $asOfDate) = @_;
    return undef unless ref($data) eq 'HASH';
    $asOfDate = cm_today() unless defined($asOfDate) && length($asOfDate);
    return undef unless defined cm_dateCompare($asOfDate, $asOfDate);
    # This API uses the latest live reading and cannot reconstruct a past date.
    return undef unless $asOfDate eq cm_today();
    my ($year) = $asOfDate =~ /^(\d{4})-/;
    my $startDate = "$year-01-01";
    my $result = cm_billingCalculatePhysicalPeriod($data, $startDate);
    return $result unless ref($result) eq 'HASH'
        && ($result->{status} // '') eq 'active';
    my $advances = cm_billingScheduledAdvances($data, $startDate, $asOfDate);
    return undef unless ref($advances) eq 'HASH';
    return {
        %$result,
        year => $year,
        calculatedTo => $asOfDate,
        advanceAmount => $advances->{amount},
        advanceCount => $advances->{count},
        financialReserve => $advances->{amount} - $result->{totalCost},
    };
}

# Current custom billing year, beginning on day one of the selected month.
sub cm_billingCalculatePhysicalBillingYear {
    my ($data, $startMonth, $asOfDate) = @_;
    return undef unless ref($data) eq 'HASH';
    $startMonth = '01' unless defined($startMonth) && length($startMonth);
    return undef unless $startMonth =~ /^(?:0[1-9]|1[0-2])$/;
    $asOfDate = cm_today() unless defined($asOfDate) && length($asOfDate);
    return undef unless defined cm_dateCompare($asOfDate, $asOfDate);
    return undef unless $asOfDate eq cm_today();
    my ($year, $month) = $asOfDate =~ /^(\d{4})-(\d{2})-/;
    my $startYear = $year - ($month < $startMonth ? 1 : 0);
    my $startDate = sprintf('%04d-%s-01', $startYear, $startMonth);
    my $result = cm_billingCalculatePhysicalPeriod($data, $startDate);
    return $result unless ref($result) eq 'HASH'
        && ($result->{status} // '') eq 'active';
    my $advances = cm_billingScheduledAdvances($data, $startDate, $asOfDate);
    return undef unless ref($advances) eq 'HASH';
    return {
        %$result,
        startDate => $startDate,
        calculatedTo => $asOfDate,
        advanceAmount => $advances->{amount},
        advanceCount => $advances->{count},
        financialReserve => $advances->{amount} - $result->{totalCost},
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

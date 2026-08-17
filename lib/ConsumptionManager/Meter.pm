package ConsumptionManager::Meter;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(CM_VERSION);
use ConsumptionManager::Utils qw(
    cm_timestamp
    cm_now
    cm_year
    cm_month
    cm_today
    cm_dateCompare
);
use ConsumptionManager::Consumption qw(cm_consumptionUpdate);
use ConsumptionManager::Tariff qw(cm_tariffCapturePendingSnapshots);

our @EXPORT_OK = qw(
    cm_meterUpdate
    cm_meterConsumption
    cm_meterValidate
    cm_meterSetYearBaseline
    cm_meterSetMonthBaseline
    cm_meterRegisterChange
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Meter

=head1 DESCRIPTION

Physical/virtual meter handling, period baselines and meter replacements.

=cut

sub _cm_meterNumber {
    my ($value) = @_;
    return defined($value)
        && $value =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub cm_meterValidate {
    my ($hash, $data, $newCounter) = @_;
    return 0 unless defined $hash && ref($data) eq 'HASH';
    return 0 unless defined $newCounter;
    return 0 unless $newCounter =~ /^\d+(?:\.\d+)?$/;
    return 1;
}

sub cm_meterConsumption {
    my ($oldCounter, $newCounter) = @_;
    $oldCounter //= 0;
    $newCounter //= 0;
    return $newCounter - $oldCounter;
}

sub cm_meterUpdate {
    my ($hash, $data, $newCounter, $counterDecimals) = @_;
    return 0 unless cm_meterValidate($hash, $data, $newCounter);

    if (defined $counterDecimals && $counterDecimals =~ /^\d+$/ && $counterDecimals <= 9) {
        $data->{meter}{counterDecimals} = 0 + $counterDecimals;
    }

    $newCounter += 0;

    my $offset = $data->{meter}{offset} // 0;
    my $newVirtual = $newCounter + $offset;

    # First live value initializes period baselines without creating usage.
    unless (defined $data->{meter}{current}) {
        my $now = cm_now();

        $data->{meter}{current}       = $newCounter;
        $data->{meter}{virtual}       = $newVirtual;
        $data->{meter}{lastTimestamp} = $now;
        $data->{meter}{lastUpdate}    = cm_timestamp();

        return 0 unless cm_consumptionUpdate($data, $newVirtual, $newVirtual);
        return 0 unless cm_tariffCapturePendingSnapshots($data, $newVirtual);
        return 1;
    }

    my $oldCounter = $data->{meter}{current};
    my $oldVirtual = _cm_meterNumber($data->{meter}{virtual})
        ? 0 + $data->{meter}{virtual}
        : $oldCounter + $offset;

    my $consumption = cm_meterConsumption($oldCounter, $newCounter);
    return 0 if $consumption < 0;

    return 0 unless cm_tariffCapturePendingSnapshots($data, $oldVirtual);

    my $now = cm_now();
    my $lastTimestamp = $data->{meter}{lastTimestamp} // $now;
    my $timeDiff = $now - $lastTimestamp;
    my $power = $timeDiff > 0 ? ($consumption * 3600) / $timeDiff : 0;

    $data->{meter}{current}       = $newCounter;
    $data->{meter}{virtual}       = $newVirtual;
    $data->{meter}{powerCurrent}  = 0 + sprintf('%.2f', $power);
    $data->{meter}{lastTimestamp} = $now;
    $data->{meter}{lastUpdate}    = cm_timestamp();

    return 0 unless cm_consumptionUpdate($data, $oldVirtual, $newVirtual);
    return 1;
}

sub _cm_meterOffsetBeforeDate {
    my ($data, $date) = @_;
    return 0 unless ref($data) eq 'HASH' && defined $date;

    my $offset = 0;
    for my $change (@{ $data->{meterChanges} || [] }) {
        next unless ref($change) eq 'HASH';
        next unless defined $change->{date} && $change->{date} lt $date;

        if (_cm_meterNumber($change->{offsetDelta})) {
            $offset += $change->{offsetDelta};
        }
        elsif (_cm_meterNumber($change->{oldCounter}) && _cm_meterNumber($change->{newCounter})) {
            $offset += $change->{oldCounter} - $change->{newCounter};
        }
    }
    return $offset;
}

sub cm_meterSetMonthBaseline {
    my ($data, $month, $counter) = @_;
    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $month && $month =~ /^\d{4}-\d{2}$/;
    return 0 unless defined $counter && $counter =~ /^\d+(?:\.\d+)?$/;
    return 0 unless $month eq cm_month();

    my $effective = (0 + $counter)
        + _cm_meterOffsetBeforeDate($data, $month . '-01');

    if (_cm_meterNumber($data->{meter}{virtual}) && $effective > $data->{meter}{virtual}) {
        return 0;
    }

    $data->{consumption} ||= {};
    $data->{consumption}{monthKey}      = $month;
    $data->{consumption}{monthBaseline} = $effective;
    return 1;
}

sub cm_meterSetYearBaseline {
    my ($data, $year, $counter) = @_;
    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $year && $year =~ /^\d{4}$/;
    return 0 unless defined $counter && $counter =~ /^\d+(?:\.\d+)?$/;
    return 0 unless $year eq cm_year();

    my $effective = (0 + $counter)
        + _cm_meterOffsetBeforeDate($data, $year . '-01-01');

    if (_cm_meterNumber($data->{meter}{virtual}) && $effective > $data->{meter}{virtual}) {
        return 0;
    }

    $data->{consumption} ||= {};
    $data->{consumption}{yearKey}      = $year;
    $data->{consumption}{yearBaseline} = $effective;
    return 1;
}

sub cm_meterRegisterChange {
    my ($data, $date, $oldCounter, $newCounter, $comment) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $date && $date =~ /^\d{4}-\d{2}-\d{2}$/;
    return 0 unless defined cm_dateCompare($date, $date);
    return 0 if cm_dateCompare($date, cm_today()) > 0;
    return 0 unless defined $oldCounter && $oldCounter =~ /^\d+(?:\.\d+)?$/;
    return 0 unless defined $newCounter && $newCounter =~ /^\d+(?:\.\d+)?$/;

    $oldCounter += 0;
    $newCounter += 0;
    $comment = '' unless defined $comment;

    $data->{meterChanges} = [] unless ref($data->{meterChanges}) eq 'ARRAY';
    for my $entry (@{ $data->{meterChanges} }) {
        next unless ref($entry) eq 'HASH';
        return 0 if (($entry->{date} // '') eq $date)
            && (($entry->{oldCounter} // -1) == $oldCounter)
            && (($entry->{newCounter} // -1) == $newCounter);
    }

    my $offsetBefore = $data->{meter}{offset} // 0;
    my $offsetDelta  = $oldCounter - $newCounter;
    my $offsetAfter  = $offsetBefore + $offsetDelta;

    push @{ $data->{meterChanges} }, {
        date         => $date,
        oldCounter   => $oldCounter,
        newCounter   => $newCounter,
        offsetDelta  => $offsetDelta,
        offsetBefore => $offsetBefore,
        offsetAfter  => $offsetAfter,
        comment      => $comment,
        created      => cm_timestamp(),
    };

    @{ $data->{meterChanges} } = sort {
        ($a->{date} // '') cmp ($b->{date} // '')
    } @{ $data->{meterChanges} };

    # Period baselines already live on the virtual scale. They must therefore
    # never be shifted when a physical meter is replaced.
    $data->{meter}{offset} = $offsetAfter;

    if (defined $data->{meter}{current}) {
        if ($data->{meter}{current} >= $oldCounter) {
            $data->{meter}{current} = $newCounter;
        }
        $data->{meter}{virtual} = $data->{meter}{current} + $offsetAfter;
    }

    return 1;
}

1;

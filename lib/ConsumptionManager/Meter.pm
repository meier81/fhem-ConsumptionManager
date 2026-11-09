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
    cm_dateSubtractDay
);

our @EXPORT_OK = qw(
    cm_meterUpdate
    cm_meterConsumption
    cm_meterValidate
    cm_meterSetBoundary
    cm_meterRegisterChange
    cm_meterEditChange
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Meter

=head1 DESCRIPTION

Physical meter readings, midnight opening values and meter replacements.

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

# The live meter is always physical. Historic usage is calculated from
# midnight boundaries and meterChanges, never from rolling offsets.
sub cm_meterUpdate {
    my ($hash, $data, $newCounter, $counterDecimals) = @_;
    return 0 unless cm_meterValidate($hash, $data, $newCounter);
    $data->{meter} ||= {};
    if (defined($counterDecimals) && $counterDecimals =~ /^\d+$/
        && $counterDecimals <= 9) {
        $data->{meter}{counterDecimals} = 0 + $counterDecimals;
    }
    $newCounter += 0;
    my $oldCounter = $data->{meter}{current};
    my $now = cm_now();
    if (defined($oldCounter)) {
        my $consumption = cm_meterConsumption($oldCounter, $newCounter);
        # Physical samples must never be discarded because a replacement
        # has not yet been entered. A negative delta is not a valid flow.
        # History/billing validates the complete sequence separately.
        if ($consumption < 0) {
            $data->{meter}{powerCurrent} = 0;
        }
        my $elapsed = $now - ($data->{meter}{lastTimestamp} // $now);
        $data->{meter}{powerCurrent} = $consumption >= 0 && $elapsed > 0
            ? 0 + sprintf('%.2f', $consumption * 3600 / $elapsed) : 0;
    } else {
        $data->{meter}{powerCurrent} = 0;
    }
    $data->{meter}{current} = $newCounter;
    $data->{meter}{lastTimestamp} = $now;
    $data->{meter}{lastUpdate} = cm_timestamp();
    return 1;
}

# Manual opening readings are physical midnight boundaries, not virtual
# consumption baselines. They can be corrected without changing live values.
sub cm_meterSetBoundary {
    my ($data, $date, $counter) = @_;
    return 0 unless ref($data) eq 'HASH'
        && defined($date) && $date =~ /^\d{4}-\d{2}-\d{2}$/
        && defined($counter) && $counter =~ /^\d+(?:\.\d+)?$/;
    $data->{counterHistory} = []
        unless ref($data->{counterHistory}) eq 'ARRAY';
    my @matches = grep { ref($_) eq 'HASH'
        && ($_->{date} // '') eq $date } @{$data->{counterHistory}};
    return 0 if @matches > 1;
    if (@matches) {
        $matches[0]{counter} = 0 + $counter;
        $matches[0]{source} = 'manual';
        $matches[0]{boundaryExact} = 1;
    } else {
        push @{$data->{counterHistory}}, {
            date => $date, counter => 0 + $counter,
            source => 'manual', boundaryExact => 1,
            capturedAt => $date . ' 00:00:00',
        };
        @{$data->{counterHistory}} = sort {
            ($a->{date} // '') cmp ($b->{date} // '')
        } @{$data->{counterHistory}};
    }
    return 1;
}

sub cm_meterRegisterChange {
    my ($data, $date, $oldCounter, $newCounter, $comment, $effectiveAt) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $date && $date =~ /^\d{4}-\d{2}-\d{2}$/;
    return 0 unless defined cm_dateCompare($date, $date);
    return 0 if cm_dateCompare($date, cm_today()) > 0;
    return 0 unless defined $oldCounter && $oldCounter =~ /^\d+(?:\.\d+)?$/;
    return 0 unless defined $newCounter && $newCounter =~ /^\d+(?:\.\d+)?$/;

    # New meter changes require a documented local timestamp.
    # Existing legacy date-only entries remain unchanged.
    return 0 unless defined($effectiveAt) && length($effectiveAt);
    {
        return 0 unless $effectiveAt =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
            && substr($effectiveAt, 0, 10) eq $date;
        my ($hh, $mm, $ss) = $effectiveAt =~ / (\d{2}):(\d{2}):(\d{2})$/;
        return 0 if $hh > 23 || $mm > 59 || $ss > 59;
        return 0 if $effectiveAt gt cm_timestamp();
    }

    $oldCounter += 0;
    $newCounter += 0;
    $comment = '' unless defined $comment;

    $data->{meterChanges} = [] unless ref($data->{meterChanges}) eq 'ARRAY';
    for my $entry (@{ $data->{meterChanges} }) {
        next unless ref($entry) eq 'HASH';
        return 0 if ($entry->{effectiveAt} // '') eq $effectiveAt;
        return 0 if (($entry->{date} // '') eq $date)
            && (($entry->{oldCounter} // -1) == $oldCounter)
            && (($entry->{newCounter} // -1) == $newCounter);
    }

    push @{$data->{meterChanges}}, {
        date => $date, oldCounter => $oldCounter,
        newCounter => $newCounter, comment => $comment,
        created => cm_timestamp(),
        (defined($effectiveAt) && length($effectiveAt)
            ? (effectiveAt => $effectiveAt) : ()),
    };
    @{$data->{meterChanges}} = sort {
        ($a->{effectiveAt} // ($a->{date} // '')) cmp
        ($b->{effectiveAt} // ($b->{date} // ''))
    } @{$data->{meterChanges}};
    # Registering an event must not overwrite an independently observed
    # physical live reading. The next meter sample establishes the new value.
    return 1;
}

# Correct an existing replacement without registering a second replacement.
# Entries are addressed by their original chronological position.
sub cm_meterEditChange {
    my ($data, $index, $date, $oldCounter, $newCounter, $comment, $effectiveAt) = @_;
    return 0 unless ref($data) eq 'HASH'
        && ref($data->{meterChanges}) eq 'ARRAY'
        && defined($index) && $index =~ /^\d+$/
        && $index < @{ $data->{meterChanges} };
    return 0 unless defined($date) && $date =~ /^\d{4}-\d{2}-\d{2}$/
        && defined(cm_dateCompare($date, $date))
        && cm_dateCompare($date, cm_today()) <= 0;
    return 0 unless defined($oldCounter) && $oldCounter =~ /^\d+(?:\.\d+)?$/
        && defined($newCounter) && $newCounter =~ /^\d+(?:\.\d+)?$/;

    my $changes = $data->{meterChanges};
    my $entry = $changes->[$index];
    return 0 unless ref($entry) eq 'HASH';


    # Historical corrections are allowed regardless of entry age, position,
    # or current live reading. The physical history calculation will flag
    # inconsistent sequences until the remaining entries are corrected.
    # Every edited entry must have an explicit time; legacy entries can be
    # completed during editing without changing their physical counters.
    return 0 unless defined($effectiveAt) && length($effectiveAt);
    {
        return 0 unless $effectiveAt =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
            && substr($effectiveAt, 0, 10) eq $date;
        my ($hh, $mm, $ss) = $effectiveAt =~ / (\d{2}):(\d{2}):(\d{2})$/;
        return 0 if $hh > 23 || $mm > 59 || $ss > 59;
        return 0 if $effectiveAt gt cm_timestamp();
        for my $i (0 .. $#$changes) {
            next if $i == $index;
            return 0 if ($changes->[$i]{effectiveAt} // '') eq $effectiveAt;
        }
        $entry->{effectiveAt} = $effectiveAt;
    }
    $entry->{date} = $date;
    $entry->{oldCounter} = 0 + $oldCounter;
    $entry->{newCounter} = 0 + $newCounter;
    $entry->{comment} = defined($comment) ? $comment : '';
    @{$data->{meterChanges}} = sort {
        ($a->{effectiveAt} // ($a->{date} // '')) cmp
        ($b->{effectiveAt} // ($b->{date} // ''))
    } @{$data->{meterChanges}};
    return 1;
}

1;

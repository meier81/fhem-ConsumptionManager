package ConsumptionManager::Tariff;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
    CM_DEFAULT_CURRENCY
);

use ConsumptionManager::Utils qw(
    cm_today
    cm_dateCompare
    cm_dateSubtractDay
);

our @EXPORT_OK = qw(
    cm_tariffCurrent
    cm_tariffFind
    cm_tariffValidate
    cm_tariffConvert
    cm_tariffCreate
    cm_tariffEdit
    cm_tariffSetValue
    cm_tariffSave
    cm_tariffCancel
    cm_tariffCapturePendingSnapshots
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Tariff

=head1 DESCRIPTION

Tariff management.

=cut

###############################################################################
# Return current tariff
###############################################################################

sub cm_tariffCurrent {
    my ($data) = @_;

    return cm_tariffFind($data, cm_today());
}

###############################################################################
# Find tariff for a given date
###############################################################################

sub cm_tariffFind {
    my ($data, $date) = @_;

    return undef unless ref($data) eq 'HASH';
    return undef unless ref($data->{tariffs}) eq 'ARRAY';

    $date = cm_today() unless defined $date && length $date;
    return undef unless defined cm_dateCompare($date, $date);

    foreach my $tariff (
        sort {
            ($b->{validFrom} // '') cmp ($a->{validFrom} // '')
        } @{$data->{tariffs}}
    ) {
        next unless ref($tariff) eq 'HASH';
        next unless defined $tariff->{validFrom};
        next if $tariff->{validFrom} gt $date;

        return $tariff
            if !defined($tariff->{validTo})
            || $tariff->{validTo} eq ''
            || $tariff->{validTo} ge $date;
    }

    return undef;
}

###############################################################################
# Validate tariff
###############################################################################

sub cm_tariffValidate {
    my ($tariff) = @_;

    return 0 unless ref($tariff) eq 'HASH';

    for my $field (qw(
        validFrom
        workPrice
        basePrice
        basePriceUnit
        currency
        unitCounter
        unitBilling
        calorificValue
        stateNumber
        assessmentFactor
        surfaceUsageArea
        surfaceUsagePrice
        surfaceRecurringArea
        surfaceRecurringPrice
    )) {
        return 0 unless exists $tariff->{$field};
    }

    return 0 unless defined cm_dateCompare($tariff->{validFrom}, $tariff->{validFrom});

    if (defined $tariff->{validTo} && $tariff->{validTo} ne '') {
        return 0 unless defined cm_dateCompare($tariff->{validTo}, $tariff->{validTo});
        return 0 if cm_dateCompare($tariff->{validTo}, $tariff->{validFrom}) < 0;
    }

    return 0 unless _cm_tariffNonNegativeNumber($tariff->{workPrice});
    return 0 unless _cm_tariffNonNegativeNumber($tariff->{basePrice});
    return 0 unless $tariff->{basePriceUnit} =~ /^(month|year)$/;
    return 0 unless $tariff->{currency} =~ /^[A-Z]{3}$/;
    return 0 unless $tariff->{unitCounter} =~ /^(kWh|Wh|m3|L)$/;
    return 0 unless $tariff->{unitBilling} =~ /^(kWh|Wh|m3|L)$/;
    return 0 unless _cm_tariffPositiveNumber($tariff->{calorificValue});
    return 0 unless _cm_tariffPositiveNumber($tariff->{stateNumber});
    return 0 unless _cm_tariffAssessmentFactor($tariff->{assessmentFactor});
    return 0 unless _cm_tariffNonNegativeNumber($tariff->{surfaceUsageArea});
    return 0 unless _cm_tariffNonNegativeNumber($tariff->{surfaceUsagePrice});
    return 0 unless _cm_tariffNonNegativeNumber($tariff->{surfaceRecurringArea});
    return 0 unless _cm_tariffNonNegativeNumber($tariff->{surfaceRecurringPrice});

    return 1;
}

###############################################################################
# Convert consumption to billing unit
###############################################################################

sub cm_tariffConvert {
    my ($consumption, $tariff) = @_;

    return undef unless _cm_tariffNonNegativeNumber($consumption);
    return undef unless ref($tariff) eq 'HASH';

    my $factor =
        ($tariff->{calorificValue} // 1)
        * ($tariff->{stateNumber} // 1)
        * ($tariff->{assessmentFactor} // 1);

    return $consumption * $factor;
}

###############################################################################
# Create tariff editor
###############################################################################

sub cm_tariffCreate {
    my ($hash, $data) = @_;

    return 0 unless ref($hash) eq 'HASH';
    return 0 unless ref($data) eq 'HASH';

    my $medium = $hash->{MEDIUM} // $data->{device}{medium} // 'electricity';
    my ($unitCounter, $unitBilling) = ('kWh', 'kWh');

    if ($medium eq 'gas') {
        ($unitCounter, $unitBilling) = ('m3', 'kWh');
    }
    elsif ($medium eq 'water' || $medium eq 'wastewater') {
        ($unitCounter, $unitBilling) = ('m3', 'm3');
    }

    $data->{tariffEditor} = {
        validFrom      => cm_today(),
        validTo        => '',
        workPrice      => 0,
        basePrice      => 0,
        basePriceUnit  => 'month',
        currency       => CM_DEFAULT_CURRENCY,
        unitCounter    => $unitCounter,
        unitBilling    => $unitBilling,
        calorificValue => 1,
        stateNumber          => 1,
        assessmentFactor    => $medium eq 'wastewater' ? 0.90 : 1,
        surfaceUsageArea      => 0,
        surfaceUsagePrice     => 0,
        surfaceRecurringArea  => 0,
        surfaceRecurringPrice => 0,
        comment              => '',
        counterSnapshot      => undef,
        counterSnapshotDate  => '',
        counterSnapshotSource => '',
        counterSnapshotExact => 0,
    };

    return 1;
}

###############################################################################
# Load an existing tariff into the editor for correcting stored data
###############################################################################

sub cm_tariffEdit {
    my ($data, $id) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $id && $id =~ /^\d+$/;
    return 0 unless ref($data->{tariffs}) eq 'ARRAY';

    for my $tariff (@{$data->{tariffs}}) {
        next unless ref($tariff) eq 'HASH';
        next unless defined $tariff->{id};
        next unless $tariff->{id} == $id;

        my %editor = %{$tariff};
        $editor{_editId} = 0 + $id;
        $editor{_editOriginalValidFrom} = $tariff->{validFrom} // '';
        $editor{_snapshotEdited} = 0;
        delete $editor{id};
        $data->{tariffEditor} = \%editor;
        return 1;
    }

    return 0;
}

###############################################################################
# Set value in tariff editor
###############################################################################

sub cm_tariffSetValue {
    my ($data, $field, $value) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless ref($data->{tariffEditor}) eq 'HASH';
    return 0 unless keys %{$data->{tariffEditor}};

    my %allowed = map { $_ => 1 } qw(
        validFrom
        validTo
        workPrice
        basePrice
        basePriceUnit
        currency
        unitCounter
        unitBilling
        calorificValue
        stateNumber
        assessmentFactor
        surfaceUsageArea
        surfaceUsagePrice
        surfaceRecurringArea
        surfaceRecurringPrice
        comment
        counterSnapshot
    );

    return 0 unless $allowed{$field};
    return 0 unless defined $value;

    if ($field =~ /^(workPrice|basePrice|counterSnapshot|surfaceUsageArea|surfaceUsagePrice|surfaceRecurringArea|surfaceRecurringPrice)$/) {
        return 0 unless _cm_tariffNonNegativeNumber($value);
        $value += 0;
    }
    elsif ($field =~ /^(calorificValue|stateNumber)$/) {
        return 0 unless _cm_tariffPositiveNumber($value);
        $value += 0;
    }
    elsif ($field eq 'assessmentFactor') {
        return 0 unless _cm_tariffNonNegativeNumber($value);
        $value += 0;
        $value /= 100 if $value > 1 && $value <= 100;
        return 0 unless _cm_tariffAssessmentFactor($value);
    }
    elsif ($field eq 'validFrom') {
        return 0 unless defined cm_dateCompare($value, $value);
    }
    elsif ($field eq 'validTo') {
        return 0 unless $value eq '' || defined cm_dateCompare($value, $value);
    }
    elsif ($field eq 'basePriceUnit') {
        return 0 unless $value =~ /^(month|year)$/;
    }
    elsif ($field eq 'currency') {
        return 0 unless $value =~ /^[A-Z]{3}$/;
    }
    elsif ($field eq 'unitCounter' || $field eq 'unitBilling') {
        return 0 unless $value =~ /^(kWh|Wh|m3|L)$/;
    }

    $data->{tariffEditor}{$field} = $value;

    if ($field eq 'counterSnapshot') {
        $data->{tariffEditor}{counterSnapshotDate}   = $data->{tariffEditor}{validFrom} // '';
        $data->{tariffEditor}{counterSnapshotSource} = 'manual';
        $data->{tariffEditor}{counterSnapshotExact}  = 1;
        $data->{tariffEditor}{_snapshotEdited} = 1
            if defined $data->{tariffEditor}{_editId};
    }
    elsif ($field eq 'validFrom'
        && $data->{tariffEditor}{_snapshotEdited}
        && defined $data->{tariffEditor}{counterSnapshot}) {
        $data->{tariffEditor}{counterSnapshotDate} = $value;
    }

    return 1;
}

###############################################################################
# Save tariff editor
###############################################################################

sub cm_tariffSave {
    my ($data) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless ref($data->{tariffEditor}) eq 'HASH';
    return 0 unless keys %{$data->{tariffEditor}};

    my %editor = %{$data->{tariffEditor}};
    my $editId = delete $editor{_editId};
    my $originalValidFrom = delete $editor{_editOriginalValidFrom};
    my $snapshotEdited = delete $editor{_snapshotEdited};
    return 0 unless cm_tariffValidate(\%editor);

    $data->{tariffs} = [] unless ref($data->{tariffs}) eq 'ARRAY';

    if (defined $editId) {
        my $index;
        for my $i (0 .. $#{$data->{tariffs}}) {
            my $entry = $data->{tariffs}[$i];
            next unless ref($entry) eq 'HASH';
            if (defined $entry->{id} && $entry->{id} == $editId) {
                $index = $i;
                last;
            }
        }
        return 0 unless defined $index;

        for my $i (0 .. $#{$data->{tariffs}}) {
            next if $i == $index;
            my $entry = $data->{tariffs}[$i];
            next unless ref($entry) eq 'HASH';
            return 0 if ($entry->{validFrom} // '') eq ($editor{validFrom} // '');
        }

        my $old = $data->{tariffs}[$index];
        $editor{id} = 0 + $editId;

        if (($old->{validFrom} // '') ne ($editor{validFrom} // '')) {
            unless ($snapshotEdited) {
                $editor{counterSnapshot}       = undef;
                $editor{counterSnapshotDate}   = '';
                $editor{counterSnapshotSource} = '';
                $editor{counterSnapshotExact}  = 0;
                _cm_tariffInitializeSnapshot($data, \%editor);
            }
        }

        $data->{tariffs}[$index] = \%editor;
    }
    else {
        my $latest;
        if (@{$data->{tariffs}}) {
            ($latest) = sort {
                ($b->{validFrom} // '') cmp ($a->{validFrom} // '')
            } grep {
                ref($_) eq 'HASH' && defined $_->{validFrom}
            } @{$data->{tariffs}};
        }

        if (defined $latest) {
            my $comparison = cm_dateCompare($editor{validFrom}, $latest->{validFrom});
            return 0 unless defined $comparison;
            return 0 if $comparison <= 0;
        }

        my $nextId = 1;
        for my $tariff (@{$data->{tariffs}}) {
            next unless ref($tariff) eq 'HASH';
            next unless defined $tariff->{id} && $tariff->{id} =~ /^\d+$/;
            $nextId = $tariff->{id} + 1 if $tariff->{id} >= $nextId;
        }

        $editor{id} = $nextId;
        _cm_tariffInitializeSnapshot($data, \%editor);
        push @{$data->{tariffs}}, \%editor;
    }

    @{$data->{tariffs}} = sort {
        ($a->{validFrom} // '') cmp ($b->{validFrom} // '')
    } @{$data->{tariffs}};

    for my $i (0 .. $#{$data->{tariffs}}) {
        my $entry = $data->{tariffs}[$i];
        next unless ref($entry) eq 'HASH';
        if ($i < $#{$data->{tariffs}}) {
            my $next = $data->{tariffs}[$i + 1];
            my $validTo = cm_dateSubtractDay($next->{validFrom});
            return 0 unless defined $validTo;
            $entry->{validTo} = $validTo;
        }
        else {
            $entry->{validTo} = '';
        }
    }

    $data->{tariffEditor} = {};
    return 1;
}

###############################################################################
# Capture snapshots for tariffs that became valid after they were created
###############################################################################

sub cm_tariffCapturePendingSnapshots {
    my ($data, $snapshot) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless _cm_tariffNonNegativeNumber($snapshot);
    return 1 unless ref($data->{tariffs}) eq 'ARRAY';

    my $today = cm_today();

    for my $tariff (@{$data->{tariffs}}) {
        next unless ref($tariff) eq 'HASH';
        next unless defined $tariff->{validFrom};
        next if $tariff->{validFrom} gt $today;
        next if defined $tariff->{counterSnapshot};
        next unless ($tariff->{counterSnapshotSource} // '') eq 'pending';

        $tariff->{counterSnapshot}       = 0 + $snapshot;
        $tariff->{counterSnapshotDate}   = $today;
        $tariff->{counterSnapshotSource} = 'automatic';
        $tariff->{counterSnapshotExact}  = $tariff->{validFrom} eq $today ? 1 : 0;
    }

    return 1;
}

###############################################################################
# Initialize the counter snapshot of a newly saved tariff
###############################################################################

sub _cm_tariffInitializeSnapshot {
    my ($data, $tariff) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless ref($tariff) eq 'HASH';

    my $manualSnapshot = $tariff->{counterSnapshot};

    if (_cm_tariffNonNegativeNumber($manualSnapshot)) {
        $tariff->{counterSnapshot}       = 0 + $manualSnapshot;
        $tariff->{counterSnapshotDate}   = $tariff->{validFrom} // '';
        $tariff->{counterSnapshotSource} = 'manual';
        $tariff->{counterSnapshotExact}  = 1;
        return 1;
    }

    $tariff->{counterSnapshot}       = undef;
    $tariff->{counterSnapshotDate}   = '';
    $tariff->{counterSnapshotSource} = 'pending';
    $tariff->{counterSnapshotExact}  = 0;

    my $validFrom = $tariff->{validFrom};
    return 1 unless defined $validFrom;

    my $today = cm_today();
    return 1 if $validFrom gt $today;

    my $baseline = _cm_tariffBaselineSnapshot($data, $validFrom);

    if (defined $baseline) {
        $tariff->{counterSnapshot}       = $baseline;
        $tariff->{counterSnapshotDate}   = $validFrom;
        $tariff->{counterSnapshotSource} = 'yearBaseline';
        $tariff->{counterSnapshotExact}  = 1;
        return 1;
    }

    my $virtual = _cm_tariffCurrentVirtualCounter($data);
    return 1 unless defined $virtual;

    $tariff->{counterSnapshot}       = $virtual;
    $tariff->{counterSnapshotDate}   = $today;
    $tariff->{counterSnapshotSource} = 'currentCounter';
    $tariff->{counterSnapshotExact}  = $validFrom eq $today ? 1 : 0;

    return 1;
}

sub _cm_tariffCurrentVirtualCounter {
    my ($data) = @_;

    return undef unless ref($data) eq 'HASH';
    return undef unless ref($data->{meter}) eq 'HASH';

    return undef unless _cm_tariffNonNegativeNumber($data->{meter}{current});

    return 0 + $data->{meter}{virtual}
        if _cm_tariffNonNegativeNumber($data->{meter}{virtual});

    return 0 + $data->{meter}{current} + ($data->{meter}{offset} // 0);
}

sub _cm_tariffBaselineSnapshot {
    my ($data, $date) = @_;

    return undef unless defined $date;
    return undef unless $date =~ /^(\d{4})-01-01$/;
    return undef unless ref($data->{consumption}) eq 'HASH';
    return undef unless ($data->{consumption}{yearKey} // '') eq $1;

    my $snapshot = $data->{consumption}{yearBaseline};
    return undef unless _cm_tariffNonNegativeNumber($snapshot);

    return 0 + $snapshot;
}

###############################################################################
# Cancel tariff editor
###############################################################################

sub cm_tariffCancel {
    my ($data) = @_;

    return 0 unless ref($data) eq 'HASH';

    $data->{tariffEditor} = {};

    return 1;
}

sub _cm_tariffNumber {
    my ($value) = @_;
    return defined($value)
        && $value =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub _cm_tariffNonNegativeNumber {
    my ($value) = @_;
    return defined($value)
        && $value =~ /^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub _cm_tariffPositiveNumber {
    my ($value) = @_;
    return _cm_tariffNonNegativeNumber($value) && $value > 0;
}

sub _cm_tariffAssessmentFactor {
    my ($value) = @_;
    return _cm_tariffNonNegativeNumber($value) && $value > 0 && $value <= 1;
}

1;

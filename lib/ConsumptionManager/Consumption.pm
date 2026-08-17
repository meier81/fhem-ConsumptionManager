package ConsumptionManager::Consumption;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(CM_VERSION);
use ConsumptionManager::Utils qw(cm_dateKeys);

our @EXPORT_OK = qw(
    cm_consumptionUpdate
    cm_consumptionToday
    cm_consumptionMonth
    cm_consumptionYear
    cm_consumptionYesterday
    cm_consumptionLastMonth
    cm_consumptionLastYear
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Consumption

=head1 DESCRIPTION

Current-period consumption calculation based on one virtual-counter baseline per
period. No daily/monthly/yearly time series are stored.

=cut

sub _cm_consumptionNumber {
    my ($value) = @_;
    return defined($value)
        && $value =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub _cm_consumptionCurrentVirtual {
    my ($data) = @_;
    return undef unless ref($data) eq 'HASH';
    return undef unless ref($data->{meter}) eq 'HASH';

    return 0 + $data->{meter}{virtual}
        if _cm_consumptionNumber($data->{meter}{virtual});

    return undef unless _cm_consumptionNumber($data->{meter}{current});
    return 0 + $data->{meter}{current} + ($data->{meter}{offset} // 0);
}

sub _cm_consumptionValue {
    my ($data, $baselineField) = @_;

    my $virtual = _cm_consumptionCurrentVirtual($data);
    return 0 unless defined $virtual;

    my $baseline = $data->{consumption}{$baselineField};
    return 0 unless _cm_consumptionNumber($baseline);
    return 0 if $baseline > $virtual;

    return $virtual - $baseline;
}

###############################################################################
# Update period rollovers using the old virtual counter as the boundary value.
# The new reading is then measured against the newly created baseline.
###############################################################################

sub cm_consumptionUpdate {
    my ($data, $oldVirtual, $newVirtual) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless _cm_consumptionNumber($oldVirtual);
    return 0 unless _cm_consumptionNumber($newVirtual);

    $data->{consumption} ||= {};
    my $c = $data->{consumption};

    my ($day, $month, $year) = cm_dateKeys();

    # First initialization. Existing correction baselines for the current
    # month/year are deliberately preserved.
    if (($c->{dayKey} // '') eq '') {
        $c->{dayKey}      = $day;
        $c->{dayBaseline} = 0 + $oldVirtual
            unless _cm_consumptionNumber($c->{dayBaseline});
    }
    if (($c->{monthKey} // '') eq '') {
        $c->{monthKey} = $month;
        $c->{monthBaseline} = 0 + $oldVirtual
            unless _cm_consumptionNumber($c->{monthBaseline});
    }
    if (($c->{yearKey} // '') eq '') {
        $c->{yearKey} = $year;
        $c->{yearBaseline} = 0 + $oldVirtual
            unless _cm_consumptionNumber($c->{yearBaseline});
    }

    if (($c->{dayKey} // '') ne $day) {
        my $baseline = $c->{dayBaseline};
        $c->{yesterday} =
            _cm_consumptionNumber($baseline) && $oldVirtual >= $baseline
                ? $oldVirtual - $baseline
                : 0;
        $c->{dayKey}      = $day;
        $c->{dayBaseline} = 0 + $oldVirtual;
    }

    if (($c->{monthKey} // '') ne $month) {
        my $baseline = $c->{monthBaseline};
        $c->{lastMonthValue} =
            _cm_consumptionNumber($baseline) && $oldVirtual >= $baseline
                ? $oldVirtual - $baseline
                : 0;
        $c->{monthKey}      = $month;
        $c->{monthBaseline} = 0 + $oldVirtual;
    }

    if (($c->{yearKey} // '') ne $year) {
        my $baseline = $c->{yearBaseline};
        $c->{lastYearValue} =
            _cm_consumptionNumber($baseline) && $oldVirtual >= $baseline
                ? $oldVirtual - $baseline
                : 0;
        $c->{yearKey}      = $year;
        $c->{yearBaseline} = 0 + $oldVirtual;
    }

    return 1;
}

sub cm_consumptionToday {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    return _cm_consumptionValue($data, 'dayBaseline');
}

sub cm_consumptionYesterday {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    return $data->{consumption}{yesterday} // 0;
}

sub cm_consumptionMonth {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    return _cm_consumptionValue($data, 'monthBaseline');
}

sub cm_consumptionLastMonth {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    return $data->{consumption}{lastMonthValue} // 0;
}

sub cm_consumptionYear {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    return _cm_consumptionValue($data, 'yearBaseline');
}

sub cm_consumptionLastYear {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    return $data->{consumption}{lastYearValue} // 0;
}

1;

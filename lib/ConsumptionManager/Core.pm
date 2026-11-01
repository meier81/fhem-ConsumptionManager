package ConsumptionManager::Core;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Storage qw(
    cm_storageLoad
    cm_storageSave
    cm_storageCreate
);

use ConsumptionManager::Utils qw(
    cm_timestamp
);

use ConsumptionManager::Meter qw(
    cm_meterUpdate
    cm_meterSetBoundary
    cm_meterRegisterChange
);

our @EXPORT_OK = qw(
    cm_coreInitializeDevice
    cm_coreLoad
    cm_coreSave
    cm_coreSetCounter
    cm_coreResetPower
    cm_coreSetBoundary
    cm_coreRegisterMeterChange
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Core

=head1 DESCRIPTION

Core functions of the ConsumptionManager.

=cut

sub cm_coreInitializeDevice {
    my ($hash, $medium) = @_;

    return undef unless defined $hash;

    my $data = cm_storageLoad($hash);

    unless ($data) {
        return undef unless cm_storageCreate($hash);
        $data = cm_storageLoad($hash);
    }

    return undef unless $data;

    my $changed = 0;
    my $name = $hash->{NAME} // '';

    if (($data->{device}{name} // '') ne $name) {
        $data->{device}{name} = $name;
        $changed = 1;
    }

    if (defined $medium && ($data->{device}{medium} // '') ne $medium) {
        $data->{device}{medium} = $medium;
        $changed = 1;
    }

    if (!$data->{device}{created}) {
        $data->{device}{created} = cm_timestamp();
        $changed = 1;
    }

    return undef if $changed && !cm_storageSave($hash, $data);

    return $data;
}

sub cm_coreLoad {
    my ($hash) = @_;

    return undef unless defined $hash;

    return cm_storageLoad($hash);
}

###############################################################################
# Save storage
###############################################################################

sub cm_coreSave {

    my ($hash, $data) = @_;

    return 0
        unless defined $hash;

    return 0
        unless defined $data;

    return cm_storageSave(
        $hash,
        $data
    );
}

sub cm_coreSetCounter {
    my ($hash, $value, $counterDecimals) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $value;
    return 0 unless $value =~ /^\d+(?:\.\d+)?$/;

    my $data = cm_storageLoad($hash);

    unless ($data) {
        $data = cm_coreInitializeDevice($hash, $hash->{MEDIUM});
    }

    return 0 unless $data;

    return 0 unless cm_meterUpdate(
        $hash,
        $data,
        $value,
        $counterDecimals
    );

    return cm_storageSave($hash, $data);
}

###############################################################################
# Reset current power to zero
###############################################################################

sub cm_coreResetPower {
    my ($hash) = @_;

    return 0 unless defined $hash;

    my $data = cm_storageLoad($hash);

    return 0 unless $data;

    return 1 if (($data->{meter}{powerCurrent} // 0) == 0);

    $data->{meter}{powerCurrent} = 0;

    return cm_storageSave($hash, $data);
}

###############################################################################
# Store or correct a physical midnight counter boundary
###############################################################################
sub cm_coreSetBoundary {
    my ($hash, $date, $counter) = @_;
    return 0 unless defined $hash;
    my $data = cm_storageLoad($hash);
    return 0 unless $data;
    return 0 unless cm_meterSetBoundary($data, $date, $counter);
    return cm_storageSave($hash, $data);
}

###############################################################################
# Register a physical meter replacement
###############################################################################

sub cm_coreRegisterMeterChange {
    my ($hash, $date, $oldCounter, $newCounter, $comment, $effectiveAt) = @_;

    return 0 unless defined $hash;

    my $data = cm_storageLoad($hash);
    return 0 unless $data;

    return 0 unless cm_meterRegisterChange(
        $data,
        $date,
        $oldCounter,
        $newCounter,
        $comment,
        $effectiveAt
    );

    return cm_storageSave($hash, $data);
}

1;

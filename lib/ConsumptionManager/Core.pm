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
);

our @EXPORT_OK = qw(
    cm_coreInitialize
    cm_coreInitializeDevice
    cm_coreLoad
    cm_coreSave
    cm_coreSetCounter
    cm_coreResetPower
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Core

=head1 DESCRIPTION

Core functions of the ConsumptionManager.

=cut

sub cm_coreInitialize {
    my ($hash) = @_;

    return unless defined $hash;

    $hash->{helper}{cm} ||= {};

    return 1;
}

sub cm_coreInitializeDevice {
    my ($hash, $medium) = @_;

    return unless defined $hash;

    my $data = cm_storageLoad($hash);

    unless ($data) {
        return undef unless cm_storageCreate($hash);
        $data = cm_storageLoad($hash);
    }

    return undef unless $data;

    $data->{device}{name} = $hash->{NAME};

    if (defined $medium) {
        $data->{device}{medium} = $medium;
    }

    if (!$data->{device}{created}) {
        $data->{device}{created} = cm_timestamp();
    }

    return undef unless cm_storageSave($hash, $data);

    return $data;
}

sub cm_coreLoad {
    my ($hash) = @_;

    return unless defined $hash;

    my $data = cm_storageLoad($hash);

    return $data;
}

sub cm_coreSave {
    my ($hash, $data) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;

    return cm_storageSave($hash, $data);
}

sub cm_coreSetCounter {
    my ($hash, $value) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $value;
    return 0 unless $value =~ /^\d+(?:\.\d+)?$/;

    my $data = cm_coreInitializeDevice($hash);

    return 0 unless $data;

    return 0 unless cm_meterUpdate(
        $hash,
        $data,
        $value
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

    return 1 if ($data->{meter}{powerCurrent} == 0);

    $data->{meter}{powerCurrent} = 0;

    return cm_storageSave($hash, $data);
}

1;

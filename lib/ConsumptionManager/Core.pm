package ConsumptionManager::Core;

use strict;
use warnings;
use Exporter 'import';
use ConsumptionManager::Storage qw(cm_storageLoad cm_storageSave cm_storageCreate);
use ConsumptionManager::Utils qw(cm_timestamp);

our @EXPORT_OK = qw(
    cm_coreInitialize
    cm_coreInitializeDevice
    cm_coreLoad
    cm_coreSave
    cm_coreSetCounter
);

our $VERSION = '0.1.0';

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

    $value += 0;

    $data->{meter}{previous} = $data->{meter}{current}
        if defined $data->{meter}{current};

    $data->{meter}{current} = $value;
    $data->{meter}{lastUpdate} = cm_timestamp();

    return cm_storageSave($hash, $data);
}

1;

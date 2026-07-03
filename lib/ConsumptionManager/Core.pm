package ConsumptionManager::Core;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
    cm_coreInitialize
    cm_coreLoad
    cm_coreSave
    cm_coreSetCounter
);

sub cm_coreInitialize {
    my ($hash) = @_;

    return unless defined $hash;

    $hash->{helper}{cm} ||= {};

    return 1;
}

sub cm_coreLoad {
    my ($hash) = @_;

    return undef unless defined $hash;

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

    my $data = cm_storageLoad($hash);

    unless ($data) {
        cm_storageCreate($hash);
        $data = cm_storageLoad($hash);
    }

    return 0 unless $data;

    $data->{meter}{current} = $value;
    $data->{meter}{lastUpdate} = cm_timestamp();

    return cm_storageSave($hash, $data);
}

1;

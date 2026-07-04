package ConsumptionManager::Meter;

use strict;
use warnings;

use Exporter 'import';

use ConsumptionManager::Utils qw(
    cm_timestamp
);

our @EXPORT_OK = qw(
    cm_meterUpdate
    cm_meterConsumption
    cm_meterValidate
);

our $VERSION = '0.1.0';

=head1 NAME

ConsumptionManager::Meter

=head1 DESCRIPTION

Meter handling and consumption calculation.

=cut

###############################################################################
# Validate a new counter value
###############################################################################

sub cm_meterValidate {
    my ($hash, $data, $newCounter) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;
    return 0 unless defined $newCounter;

    return 0 unless $newCounter =~ /^\d+(?:\.\d+)?$/;

    return 1;
}

###############################################################################
# Calculate consumption
###############################################################################

sub cm_meterConsumption {
    my ($oldCounter, $newCounter) = @_;

    $oldCounter //= 0;
    $newCounter //= 0;

    return $newCounter - $oldCounter;
}

###############################################################################
# Update meter values
###############################################################################

sub cm_meterUpdate {
    my ($hash, $data, $newCounter) = @_;

    return 0 unless cm_meterValidate($hash, $data, $newCounter);

    $newCounter += 0;

    my $oldCounter = $data->{meter}{current};

    $oldCounter = 0
        unless defined $oldCounter;

    my $consumption = cm_meterConsumption(
        $oldCounter,
        $newCounter
    );

    $data->{meter}{previous}        = $oldCounter;
    $data->{meter}{current}         = $newCounter;
    $data->{meter}{lastConsumption} = $consumption;
    $data->{meter}{lastUpdate}      = cm_timestamp();

    return 1;
}

1;

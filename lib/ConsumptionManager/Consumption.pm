package ConsumptionManager::Consumption;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Utils qw(
    cm_dateKeys
);

our @EXPORT_OK = qw(
    cm_consumptionUpdate
    cm_consumptionToday
    cm_consumptionMonth
    cm_consumptionYear
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Consumption

=head1 DESCRIPTION

Consumption calculations.

=cut

###############################################################################
# Update consumption values
###############################################################################

sub cm_consumptionUpdate {
    my (
        $hash,
        $data,
        $oldCounter,
        $newCounter,
        $consumption
    ) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;
    return 0 unless defined $consumption;

    my ($day, $month, $yearKey) = cm_dateKeys();

    $data->{consumption}{daily}{$day}{value} += $consumption;

    $data->{consumption}{monthly}{$month}{value} += $consumption;

    $data->{consumption}{yearly}{$yearKey}{value} += $consumption;

    return 1;
}

###############################################################################
# Return today's consumption
###############################################################################

sub cm_consumptionToday {

    my ($data) = @_;

    return 0 unless defined $data;

    my ($day) = cm_dateKeys();

    return $data->{consumption}{daily}{$day}{value} // 0;
}

###############################################################################
# Return current month's consumption
###############################################################################

sub cm_consumptionMonth {

    my ($data) = @_;

    return 0 unless defined $data;

    my (undef, $month) = cm_dateKeys();

    return $data->{consumption}{monthly}{$month}{value} // 0;
}

###############################################################################
# Return current year's consumption
###############################################################################

sub cm_consumptionYear {

    my ($data) = @_;

    return 0 unless defined $data;

    my (undef, undef, $yearKey) = cm_dateKeys();

    return $data->{consumption}{yearly}{$yearKey}{value} // 0;
}

1;

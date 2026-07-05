package ConsumptionManager::Cost;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionYesterday
    cm_consumptionMonth
    cm_consumptionLastMonth
    cm_consumptionYear
    cm_consumptionLastYear
);

our @EXPORT_OK = qw(
    cm_costToday
    cm_costYesterday
    cm_costMonth
    cm_costLastMonth
    cm_costYear
    cm_costLastYear
    cm_costValue
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Cost

=head1 DESCRIPTION

Cost calculation.

=cut

###############################################################################
# Generic calculation
###############################################################################

sub cm_costValue {

    my ($consumption, $price) = @_;

    $consumption //= 0;
    $price       //= 0;

    return sprintf(
        "%.2f",
        $consumption * $price
    );
}

###############################################################################
# Today's costs
###############################################################################

sub cm_costToday {

    my ($data, $price) = @_;

    return cm_costValue(
        cm_consumptionToday($data),
        $price
    );
}

###############################################################################
# Yesterday's costs
###############################################################################

sub cm_costYesterday {

    my ($data, $price) = @_;

    return cm_costValue(
        cm_consumptionYesterday($data),
        $price
    );
}

###############################################################################
# Current month's costs
###############################################################################

sub cm_costMonth {

    my ($data, $price) = @_;

    return cm_costValue(
        cm_consumptionMonth($data),
        $price
    );
}

###############################################################################
# Last month's costs
###############################################################################

sub cm_costLastMonth {

    my ($data, $price) = @_;

    return cm_costValue(
        cm_consumptionLastMonth($data),
        $price
    );
}

###############################################################################
# Current year's costs
###############################################################################

sub cm_costYear {

    my ($data, $price) = @_;

    return cm_costValue(
        cm_consumptionYear($data),
        $price
    );
}

###############################################################################
# Last year's costs
###############################################################################

sub cm_costLastYear {

    my ($data, $price) = @_;

    return cm_costValue(
        cm_consumptionLastYear($data),
        $price
    );
}

1;

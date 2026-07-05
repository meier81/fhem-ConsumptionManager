###############################################################################
#
# 98_ConsumptionManager.pm
#
# FHEM module for managing electricity, gas and water consumption.
#
###############################################################################

package main;

use strict;
use warnings;

use ConsumptionManager::Constants qw(
    CM_VERSION
    CM_DEFAULT_POWER_TIMEOUT
);

use ConsumptionManager::Core qw(
    cm_coreInitialize
    cm_coreInitializeDevice
    cm_coreLoad
    cm_coreSetCounter
    cm_coreResetPower
);

use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionYesterday
    cm_consumptionMonth
    cm_consumptionLastMonth
    cm_consumptionYear
    cm_consumptionLastYear
);

use ConsumptionManager::Tariff qw(
    cm_tariffAdd
    cm_tariffCurrent
);

our $VERSION = CM_VERSION;

=pod

=head1 NAME

FHEM::ConsumptionManager

=head1 DESCRIPTION

Consumption manager for electricity, gas and water.

=cut

#####################################
sub ConsumptionManager_Initialize($)
{
    my ($hash) = @_;

    $hash->{DefFn}    = 'ConsumptionManager_Define';
    $hash->{UndefFn}  = 'ConsumptionManager_Undef';
    $hash->{SetFn}    = 'ConsumptionManager_Set';
    $hash->{GetFn}    = 'ConsumptionManager_Get';
    $hash->{AttrFn}   = 'ConsumptionManager_Attr';

    $hash->{AttrList} =
          'alias'
        . ' room'
        . ' group'
        . ' IODev'
        . ' disable:0,1'
        . ' powerTimeout'
        . ' '.$readingFnAttributes;
}

#####################################
sub ConsumptionManager_Define($$)
{
    my ($hash, $def) = @_;

    my @a = split(/\s+/, $def);

    return "Usage: define <name> ConsumptionManager <electricity|gas|water>"
        if (@a != 3);

    my $medium = lc($a[2]);

    return "Unknown medium '$medium'"
        unless ($medium =~ /^(electricity|gas|water)$/);

    $hash->{MEDIUM} = $medium;

    cm_coreInitialize($hash);
    cm_coreInitializeDevice($hash, $medium);

    ConsumptionManager_UpdateReadings($hash);

    return undef;
}

#####################################
sub ConsumptionManager_Undef($$)
{
    my ($hash, $arg) = @_;

    return undef;
}

#####################################
sub ConsumptionManager_Set($@)
{
    my ($hash, @a) = @_;

    return "Need at least one argument"
        if (@a < 2);

    my $cmd = $a[1];

    if ($cmd eq "counter") {

        return "Usage: set ".$a[0]." counter <value>"
            if (@a != 3);

        my $value = $a[2];

        return "Invalid value"
            unless ($value =~ /^\d+(?:\.\d+)?$/);

        my $result = cm_coreSetCounter($hash, $value);

        return "Unable to save counter"
            unless ($result);

        ConsumptionManager_UpdateReadings($hash);

        RemoveInternalTimer($hash);

        my $timeout = AttrVal(
            $hash->{NAME},
            "powerTimeout",
            CM_DEFAULT_POWER_TIMEOUT
        );

        InternalTimer(
            gettimeofday() + $timeout,
            "ConsumptionManager_PowerTimeout",
            $hash,
            0
        );

        return undef;
    }

    ###############################################################################
    # set <device> tariff add ...
    ###############################################################################

    if ($cmd eq "tariff") {

        return
    "Usage: set <name> tariff add <validFrom> <workPrice> <basePrice> <day|month|year> [calorificValue] [stateNumber]"
            unless @a >= 6;

        return "Only 'add' is supported"
            unless $a[2] eq "add";

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my %tariff = (

            validFrom => $a[3],
            validTo   => '',

            workPrice => $a[4] + 0,

            basePrice => $a[5] + 0,

            basePriceUnit => $a[6],

            currency => "EUR",

            unitCounter => (
                $hash->{MEDIUM} eq "gas"
                ? "m3"
                : "kWh"
            ),

            unitBilling => "kWh",

            calorificValue =>
                defined $a[7] ? $a[7] : 1,

            stateNumber =>
                defined $a[8] ? $a[8] : 1,
        );

        return "Invalid tariff"
            unless cm_tariffAdd(
                $data,
                \%tariff
            );

        cm_coreSave(
            $hash,
            $data
        );

        return undef;
    }

    return "Unknown argument $cmd, choose one of counter";
}

#####################################
sub ConsumptionManager_Get($@)
{
    my ($hash, @a) = @_;

    return "Need at least one argument"
        if (@a < 2);

    my $cmd = $a[1];

    if ($cmd eq "counter") {

        my $data = cm_coreLoad($hash);

        return "No data available"
            unless ($data);

        return $data->{meter}{current};
    }

    return "Unknown argument $cmd, choose one of counter";
}

#####################################
sub ConsumptionManager_Attr(@)
{
    return undef;
}

###############################################################################
sub ConsumptionManager_UpdateReadings {
    my ($hash) = @_;

    my $data = cm_coreLoad($hash);

    return unless $data;

    readingsBeginUpdate($hash);

    if (defined $data->{device}{medium}) {
        readingsBulkUpdate(
            $hash,
            "medium",
            $data->{device}{medium}
        );
    }

    if (defined $data->{meter}{current}) {
        readingsBulkUpdate(
            $hash,
            "counter",
            $data->{meter}{current}
        );
    }

    if (defined $data->{meter}{lastConsumption}) {
        readingsBulkUpdate(
            $hash,
            "consumptionLast",
            $data->{meter}{lastConsumption}
        );
    }

    if (defined $data->{meter}{powerCurrent}) {
        readingsBulkUpdate(
            $hash,
            "powerCurrent",
            $data->{meter}{powerCurrent}
        );
    }

    readingsBulkUpdate(
        $hash,
        "consumptionToday",
        cm_consumptionToday($data)
    );

    readingsBulkUpdate(
        $hash,
        "consumptionMonth",
        cm_consumptionMonth($data)
    );

    readingsBulkUpdate(
        $hash,
        "consumptionYear",
        cm_consumptionYear($data)
    );

    readingsBulkUpdate(
        $hash,
        "consumptionYesterday",
        cm_consumptionYesterday($data)
    );

    readingsBulkUpdate(
        $hash,
        "consumptionLastMonth",
        cm_consumptionLastMonth($data)
    );

    readingsBulkUpdate(
        $hash,
        "consumptionLastYear",
        cm_consumptionLastYear($data)
    );

    if (defined $data->{meter}{lastUpdate}) {
        readingsBulkUpdate(
            $hash,
            "lastUpdate",
            $data->{meter}{lastUpdate}
        );
    }

    if (defined $data->{meter}{current}) {
        readingsBulkUpdate(
            $hash,
            "state",
            "active"
        );
    }
    else {
        readingsBulkUpdate(
            $hash,
            "state",
            "initialized"
        );
    }

    readingsEndUpdate($hash, 1);

    return;
}

###############################################################################
sub ConsumptionManager_PowerTimeout {

    my ($hash) = @_;

    cm_coreResetPower($hash);

    readingsSingleUpdate(
        $hash,
        "powerCurrent",
        0,
        1
    );

    return;
}

1;

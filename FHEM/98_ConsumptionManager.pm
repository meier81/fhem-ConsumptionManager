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
    cm_coreSave
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
    cm_tariffCreate
    cm_tariffSetValue
    cm_tariffSave
    cm_tariffCancel
    cm_tariffCurrent
    cm_tariffFind
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
    # tariff
    ###############################################################################

    if ($cmd eq "tariff") {

        return ConsumptionManager_SetTariff(
            $hash,
            @a
        );
    }

    return "Unknown argument $cmd, choose one of counter:noArg tariff";
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

    ###############################################################################
    # tariff
    ###############################################################################

    if ($cmd eq "tariff") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my $tariff = cm_tariffCurrent($data);

        return "No tariff defined"
            unless defined $tariff;

        my $text = "";

        $text .= "Current tariff\n";
        $text .= "==============================\n";

        $text .= sprintf(
            "%-20s %s\n",
            "Valid from:",
            $tariff->{validFrom}
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Valid to:",
            $tariff->{validTo}
        );

        $text .= sprintf(
            "%-20s %.4f\n",
            "Work price:",
            $tariff->{workPrice}
        );

        $text .= sprintf(
            "%-20s %.2f\n",
            "Base price:",
            $tariff->{basePrice}
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Base unit:",
            $tariff->{basePriceUnit}
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Counter unit:",
            $tariff->{unitCounter}
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Billing unit:",
            $tariff->{unitBilling}
        );

        $text .= sprintf(
            "%-20s %.4f\n",
            "Calorific value:",
            $tariff->{calorificValue}
        );

        $text .= sprintf(
            "%-20s %.4f\n",
           "State number:",
            $tariff->{stateNumber}
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Currency:",
            $tariff->{currency}
        );

        return $text;
    }

    return "Unknown argument $cmd, choose one of counter tariff";
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

###############################################################################
# Tariff commands
###############################################################################

sub ConsumptionManager_SetTariff {

    my ($hash, @a) = @_;

    return "Usage: set <name> tariff create|save|cancel|..."
        if @a < 3;

    my $action = $a[2];

    my $data = cm_coreLoad($hash);

    return "Unable to load storage"
        unless $data;

    #
    # create
    #

    if ($action eq "create") {

        return "Unable to create tariff"
            unless cm_tariffCreate(
                $hash,
                $data
            );

        cm_coreSave(
            $hash,
            $data
        );

        return undef;
    }

    #
    # save
    #

    if ($action eq "save") {

        return "Unable to save tariff"
            unless cm_tariffSave(
                $data
            );

        cm_coreSave(
            $hash,
            $data
        );

        return undef;
    }

    #
    # cancel
    #

    if ($action eq "cancel") {

        cm_tariffCancel(
            $data
        );

        cm_coreSave(
            $hash,
            $data
        );

        return undef;
    }

    ###############################################################################
    # set value
    ###############################################################################

    if (@a == 4) {

        my $field = $action;
        my $value = $a[3];

        return "Invalid tariff value"
            unless cm_tariffSetValue(
                $data,
                $field,
                $value
            );

        return "Unable to save storage"
            unless cm_coreSave(
                $hash,
                $data
            );

        return undef;
    }

    return "Unknown tariff command, choose one of create save cancel validFrom validTo workPrice basePrice basePriceUnit currency unitCounter unitBilling calorificValue stateNumber comment";
}

1;

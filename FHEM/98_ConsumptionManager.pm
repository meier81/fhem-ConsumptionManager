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

use ConsumptionManager::Core qw(
    cm_coreInitialize
    cm_coreLoad
    cm_coreSave
    cm_coreSetCounter
);

our $VERSION = '0.1.0';

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

    # JSON-Datei anlegen, falls sie noch nicht existiert
    my $data = cm_coreLoad($hash);

    unless ($data) {
        cm_storageCreate($hash);
        $data = cm_coreLoad($hash);
    }

    if ($data) {
        $data->{device}{medium} = $medium;
        cm_coreSave($hash, $data);
    }

    readingsSingleUpdate($hash, "state", "initialized", 1);
    readingsSingleUpdate($hash, "medium", $medium, 1);

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

        readingsSingleUpdate($hash, "counter", $value, 1);
        readingsSingleUpdate($hash, "state", "active", 1);

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

1;

=pod

=head1 NAME

FHEM::ConsumptionManager

=head1 DESCRIPTION

Consumption manager for electricity, gas and water.

=cut
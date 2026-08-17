###############################################################################
#
# 98_ConsumptionManager.pm
#
# FHEM module for managing electricity, gas, water and wastewater consumption.
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
    cm_coreInitializeDevice
    cm_coreLoad
    cm_coreSave
    cm_coreSetCounter
    cm_coreResetPower
    cm_coreSetYearBaseline
    cm_coreSetMonthBaseline
    cm_coreRegisterMeterChange
);

use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionYesterday
    cm_consumptionMonth
    cm_consumptionLastMonth
    cm_consumptionYear
    cm_consumptionLastYear
);

use ConsumptionManager::Cost qw(
    cm_costToday
    cm_costYesterday
    cm_costMonth
    cm_costLastMonth
    cm_costYear
    cm_costLastYear
);

use ConsumptionManager::Tariff qw(
    cm_tariffCreate
    cm_tariffEdit
    cm_tariffSetValue
    cm_tariffSave
    cm_tariffCancel
    cm_tariffCurrent
    cm_tariffValidate
);

use ConsumptionManager::Advance qw(
    cm_advanceCreate
    cm_advanceEdit
    cm_advanceSetValue
    cm_advanceSave
    cm_advanceCancel
    cm_advanceCurrent
    cm_advanceValidate
);

use ConsumptionManager::Billing qw(
    cm_billingCalculate
    cm_billingCalculatePeriod
    cm_billingCalculatePreviousPeriod
);

use ConsumptionManager::Utils qw(
    cm_year
    cm_month
);

our $VERSION = CM_VERSION;
our $readingFnAttributes;
our %defs;

=pod

=head1 NAME

FHEM::ConsumptionManager

=head1 DESCRIPTION

Consumption manager for electricity, gas, water and wastewater.

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
    $hash->{NotifyFn} = 'ConsumptionManager_Notify';

    $hash->{AttrList} =
          'alias'
        . ' room'
        . ' group'
        . ' IODev'
        . ' disable:0,1'
        . ' powerTimeout'
        . ' counterDevice'
        . ' counterReading'
        . ' counterMultiplier'
        . ' consumptionDecimals'
        . ' '.$readingFnAttributes;
}

#####################################
sub ConsumptionManager_Define($$)
{
    my ($hash, $def) = @_;

    my @a = split(/\s+/, $def);

    return "Usage: define <name> ConsumptionManager <electricity|gas|water|wastewater>"
        if (@a != 3);

    my $medium = lc($a[2]);

    return "Unknown medium '$medium'"
        unless ($medium =~ /^(electricity|gas|water|wastewater)$/);

    $hash->{MEDIUM} = $medium;
    $hash->{NOTIFYDEV} = AttrVal($hash->{NAME}, 'counterDevice', 'global');

    cm_coreInitializeDevice($hash, $medium);

    # Remove obsolete diagnostic/technical readings from older versions.
    for my $reading (qw(firstCounter meterOffset consumptionLast advanceCount)) {
        readingsDelete($hash, $reading)
            if ref($hash->{READINGS}) eq 'HASH' && exists $hash->{READINGS}{$reading};
    }

    ConsumptionManager_UpdateReadings($hash);

    return undef;
}

#####################################
sub ConsumptionManager_Undef($$)
{
    my ($hash, $arg) = @_;

    RemoveInternalTimer($hash);

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

        return ConsumptionManager_ProcessCounterValue(
            $hash,
            $value,
            ConsumptionManager_DecimalPlaces($value)
        );
    }

    ###############################################################################
    # Optional correction for a monthly start counter
    ###############################################################################

    if ($cmd eq "monthBaseline") {

        return "Usage: set ".$a[0]." monthBaseline <YYYY-MM> <counter>"
            if (@a != 4);

        my ($month, $counter) = @a[2, 3];

        return "Invalid month"
            unless defined $month && $month =~ /^\d{4}-\d{2}$/;

        return "Invalid counter"
            unless defined $counter && $counter =~ /^\d+(?:\.\d+)?$/;

        return "Unable to save month baseline"
            unless cm_coreSetMonthBaseline(
                $hash,
                $month,
                $counter
            );

        ConsumptionManager_UpdateReadings($hash);

        return undef;
    }

    ###############################################################################
    # Optional correction for a yearly start counter
    ###############################################################################

    if ($cmd eq "yearBaseline") {

        return "Usage: set ".$a[0]." yearBaseline <year> <counter>"
            if (@a != 4);

        my ($year, $counter) = @a[2, 3];

        return "Invalid year"
            unless defined $year && $year =~ /^\d{4}$/;

        return "Invalid counter"
            unless defined $counter && $counter =~ /^\d+(?:\.\d+)?$/;

        return "Unable to save year baseline"
            unless cm_coreSetYearBaseline(
                $hash,
                $year,
                $counter
            );

        ConsumptionManager_UpdateReadings($hash);

        return undef;
    }

    ###############################################################################
    # Dated physical meter replacement
    ###############################################################################

    if ($cmd eq "meterChange") {

        return "Usage: set ".$a[0]." meterChange <YYYY-MM-DD> <oldCounter> <newCounter> [comment]"
            if (@a < 5);

        my ($date, $oldCounter, $newCounter) = @a[2, 3, 4];
        my $comment = @a > 5 ? join(" ", @a[5 .. $#a]) : '';

        return "Invalid date"
            unless defined $date && $date =~ /^\d{4}-\d{2}-\d{2}$/;

        return "Invalid old counter"
            unless defined $oldCounter && $oldCounter =~ /^\d+(?:\.\d+)?$/;

        return "Invalid new counter"
            unless defined $newCounter && $newCounter =~ /^\d+(?:\.\d+)?$/;

        return "Unable to save meter change"
            unless cm_coreRegisterMeterChange(
                $hash,
                $date,
                $oldCounter,
                $newCounter,
                $comment
            );

        ConsumptionManager_UpdateReadings($hash);

        return undef;
    }

    ###############################################################################
    # FHEMWEB-friendly flat tariff commands
    ###############################################################################

    my %tariffCommands = (
        tariffCreate          => 'create',
        tariffEdit            => 'edit',
        tariffSave            => 'save',
        tariffCancel          => 'cancel',
        tariffValidFrom       => 'validFrom',
        tariffWorkPrice       => 'workPrice',
        tariffBasePrice       => 'basePrice',
        tariffBasePriceUnit   => 'basePriceUnit',
        tariffCurrency        => 'currency',
        tariffCalorificValue  => 'calorificValue',
        tariffStateNumber     => 'stateNumber',
        tariffAssessmentFactor => 'assessmentFactor',
        tariffSurfaceUsageArea       => 'surfaceUsageArea',
        tariffSurfaceUsagePrice      => 'surfaceUsagePrice',
        tariffSurfaceRecurringArea   => 'surfaceRecurringArea',
        tariffSurfaceRecurringPrice  => 'surfaceRecurringPrice',
        tariffComment         => 'comment',
        tariffCounterSnapshot => 'counterSnapshot',
    );

    if (exists $tariffCommands{$cmd}) {

        my $action = $tariffCommands{$cmd};

        if ($action =~ /^(create|save|cancel)$/) {
            return "Usage: set ".$a[0]." ".$cmd
                if @a != 2;

            return ConsumptionManager_SetTariff(
                $hash,
                $action
            );
        }

        if ($action eq 'edit') {
            return "Usage: set ".$a[0]." tariffEdit <id>" if @a != 3;
            return ConsumptionManager_SetTariff($hash, $action, $a[2]);
        }

        return "Usage: set ".$a[0]." ".$cmd." <value>"
            if @a < 3;

        my @values = @a[2 .. $#a];

        return ConsumptionManager_SetTariff(
            $hash,
            $action,
            @values
        );
    }

    ###############################################################################
    # FHEMWEB-friendly flat advance commands
    ###############################################################################

    my %advanceCommands = (
        advanceCreate    => 'create',
        advanceEdit      => 'edit',
        advanceSave      => 'save',
        advanceCancel    => 'cancel',
        advanceValidFrom => 'validFrom',
        advanceValidTo   => 'validTo',
        advanceAmount    => 'amount',
        advanceComment   => 'comment',
    );

    if (exists $advanceCommands{$cmd}) {

        my $action = $advanceCommands{$cmd};
        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        if ($action eq 'create') {
            return "Usage: set ".$a[0]." advanceCreate"
                if @a != 2;

            return "Unable to create advance editor"
                unless cm_advanceCreate($data);
        }
        elsif ($action eq 'edit') {
            return "Usage: set ".$a[0]." advanceEdit <id>" if @a != 3;
            return "Unable to load advance into editor"
                unless cm_advanceEdit($data, $a[2]);
        }
        elsif ($action eq 'save') {
            return "Usage: set ".$a[0]." advanceSave"
                if @a != 2;

            return "Unable to save advance"
                unless cm_advanceSave($data);
        }
        elsif ($action eq 'cancel') {
            return "Usage: set ".$a[0]." advanceCancel"
                if @a != 2;

            return "Unable to cancel advance editor"
                unless cm_advanceCancel($data);
        }
        else {
            return "Usage: set ".$a[0]." ".$cmd." <value>"
                if @a < 3;

            my $value = $action eq 'comment'
                ? join(' ', @a[2 .. $#a])
                : $a[2];

            return "Invalid advance value"
                unless cm_advanceSetValue(
                    $data,
                    $action,
                    $value
                );
        }

        return "Unable to save storage"
            unless cm_coreSave($hash, $data);

        ConsumptionManager_UpdateReadings($hash);

        return undef;
    }


    return ConsumptionManager_SetList($hash, $cmd);
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
    # monthBaseline
    ###############################################################################

    if ($cmd eq "monthBaseline") {
        return "Usage: get ".$a[0]." monthBaseline [YYYY-MM]" if @a > 3;

        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;

        my $month = cm_month();
        if (@a == 3) {
            return "Invalid month" unless $a[2] =~ /^\d{4}-\d{2}$/;
            return "No month baseline history is stored; only the current month is available"
                unless $a[2] eq $month;
        }

        return "No month baseline defined for ".$month
            unless ($data->{consumption}{monthKey} // '') eq $month
            && defined $data->{consumption}{monthBaseline};

        return sprintf("%s: %.6f", $month, $data->{consumption}{monthBaseline});
    }

    ###############################################################################
    # yearBaseline
    ###############################################################################

    if ($cmd eq "yearBaseline") {
        return "Usage: get ".$a[0]." yearBaseline [YYYY]" if @a > 3;

        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;

        my $year = cm_year();
        if (@a == 3) {
            return "Invalid year" unless $a[2] =~ /^\d{4}$/;
            return "No year baseline history is stored; only the current year is available"
                unless $a[2] eq $year;
        }

        return "No year baseline defined for ".$year
            unless ($data->{consumption}{yearKey} // '') eq $year
            && defined $data->{consumption}{yearBaseline};

        return sprintf("%s: %.6f", $year, $data->{consumption}{yearBaseline});
    }

    ###############################################################################
    # meterChanges
    ###############################################################################

    if ($cmd eq "meterChanges") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my $changes = $data->{meterChanges};

        return "No meter changes defined"
            unless ref($changes) eq 'ARRAY' && @{$changes};

        my $text = "Meter changes\n";
        $text .= "==============================\n";

        for my $change (@{$changes}) {
            $text .= sprintf(
                "%s: %.6f -> %.6f, offset %.6f",
                $change->{date} // '',
                $change->{oldCounter} // 0,
                $change->{newCounter} // 0,
                $change->{offsetAfter} // 0
            );

            $text .= " (".($change->{comment} // '').")"
                if defined $change->{comment} && $change->{comment} ne '';

            $text .= "\n";
        }

        return $text;
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

        if (($hash->{MEDIUM} // '') eq 'wastewater') {
            $text .= sprintf(
                "%-28s %.2f %%\n",
                "Assessment factor:",
                ($tariff->{assessmentFactor} // 1) * 100
            );

            $text .= sprintf(
                "%-28s %.2f m2\n",
                "Surface usage area:",
                $tariff->{surfaceUsageArea} // 0
            );
            $text .= sprintf(
                "%-28s %.4f %s/m2/year\n",
                "Surface usage price:",
                $tariff->{surfaceUsagePrice} // 0,
                $tariff->{currency} // 'EUR'
            );

            $text .= sprintf(
                "%-28s %.2f m2\n",
                "Surface recurring area:",
                $tariff->{surfaceRecurringArea} // 0
            );
            $text .= sprintf(
                "%-28s %.4f %s/m2/year\n",
                "Surface recurring price:",
                $tariff->{surfaceRecurringPrice} // 0,
                $tariff->{currency} // 'EUR'
            );
        }

        $text .= sprintf(
            "%-20s %s\n",
            "Currency:",
            $tariff->{currency}
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Counter snapshot:",
            defined $tariff->{counterSnapshot}
                ? $tariff->{counterSnapshot}
                : "pending"
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Snapshot date:",
            $tariff->{counterSnapshotDate} // ""
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Snapshot source:",
            $tariff->{counterSnapshotSource} // ""
        );

        $text .= sprintf(
            "%-20s %s\n",
            "Snapshot exact:",
            $tariff->{counterSnapshotExact} ? "yes" : "no"
        );

        return $text;
    }

    ###############################################################################
    # tariffHistory
    ###############################################################################

    if ($cmd eq "tariffHistory") {
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;
        return "No tariffs defined"
            unless ref($data->{tariffs}) eq 'ARRAY' && @{$data->{tariffs}};

        my $text = "Tariff history\n";
        $text .= "==============================\n";

        for my $tariff (sort {
            ($a->{validFrom} // '') cmp ($b->{validFrom} // '')
        } @{$data->{tariffs}}) {
            next unless ref($tariff) eq 'HASH';
            $text .= sprintf(
                "ID %s | %s - %s: %.6f %s/%s, base %.2f %s/%s\n",
                defined $tariff->{id} ? $tariff->{id} : '-',
                $tariff->{validFrom} // '',
                ($tariff->{validTo} // '') ne '' ? $tariff->{validTo} : 'open',
                $tariff->{workPrice} // 0,
                $tariff->{currency} // 'EUR',
                $tariff->{unitBilling} // '',
                $tariff->{basePrice} // 0,
                $tariff->{currency} // 'EUR',
                $tariff->{basePriceUnit} // ''
            );
            $text .= sprintf(
                "  snapshot: %s, date %s, source %s, exact %s\n",
                defined $tariff->{counterSnapshot} ? $tariff->{counterSnapshot} : 'pending',
                $tariff->{counterSnapshotDate} // '',
                $tariff->{counterSnapshotSource} // '',
                $tariff->{counterSnapshotExact} ? 'yes' : 'no'
            );
            if (($hash->{MEDIUM} // '') eq 'wastewater') {
                $text .= sprintf(
                    "  assessment %.2f %%, usage %.2f m2 x %.4f %s/m2/year, recurring %.2f m2 x %.4f %s/m2/year\n",
                    ($tariff->{assessmentFactor} // 1) * 100,
                    $tariff->{surfaceUsageArea} // 0,
                    $tariff->{surfaceUsagePrice} // 0,
                    $tariff->{currency} // 'EUR',
                    $tariff->{surfaceRecurringArea} // 0,
                    $tariff->{surfaceRecurringPrice} // 0,
                    $tariff->{currency} // 'EUR'
                );
            }
        }

        return $text;
    }

    ###############################################################################
    # tariffEditor
    ###############################################################################

    if ($cmd eq "tariffEditor") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my $editor = $data->{tariffEditor};

        return "No tariff editor active"
            unless ref($editor) eq 'HASH' && keys %{$editor};

        my $status = cm_tariffValidate($editor)
            ? 'ready to save'
            : 'incomplete';

        my $text = "Tariff editor\n";
        $text .= "==============================\n";
        $text .= sprintf("%-20s %s\n", "Mode:", defined $editor->{_editId} ? 'edit' : 'new');
        $text .= sprintf("%-20s %s\n", "Tariff ID:", $editor->{_editId}) if defined $editor->{_editId};
        $text .= sprintf("%-20s %s\n", "Valid from:", $editor->{validFrom} // '');
        $text .= sprintf("%-20s %.6f\n", "Work price:", $editor->{workPrice} // 0);
        $text .= sprintf("%-20s %.2f\n", "Base price:", $editor->{basePrice} // 0);
        $text .= sprintf("%-20s %s\n", "Base unit:", $editor->{basePriceUnit} // '');
        $text .= sprintf("%-20s %s\n", "Currency:", $editor->{currency} // '');
        $text .= sprintf("%-20s %s\n", "Counter unit:", $editor->{unitCounter} // '');
        $text .= sprintf("%-20s %s\n", "Billing unit:", $editor->{unitBilling} // '');
        $text .= sprintf("%-20s %.4f\n", "Calorific value:", $editor->{calorificValue} // 1);
        $text .= sprintf("%-20s %.4f\n", "State number:", $editor->{stateNumber} // 1);
        if (($hash->{MEDIUM} // '') eq 'wastewater') {
            $text .= sprintf("%-28s %.2f %%\n", "Assessment factor:", ($editor->{assessmentFactor} // 1) * 100);
            $text .= sprintf("%-28s %.2f m2\n", "Surface usage area:", $editor->{surfaceUsageArea} // 0);
            $text .= sprintf("%-28s %.4f %s/m2/year\n", "Surface usage price:", $editor->{surfaceUsagePrice} // 0, $editor->{currency} // 'EUR');
            $text .= sprintf("%-28s %.2f m2\n", "Surface recurring area:", $editor->{surfaceRecurringArea} // 0);
            $text .= sprintf("%-28s %.4f %s/m2/year\n", "Surface recurring price:", $editor->{surfaceRecurringPrice} // 0, $editor->{currency} // 'EUR');
        }
        $text .= sprintf("%-20s %s\n", "Comment:", $editor->{comment} // '');
        $text .= sprintf("%-20s %s\n", "Counter snapshot:", defined $editor->{counterSnapshot} ? $editor->{counterSnapshot} : 'automatic');
        $text .= sprintf("%-20s %s\n", "Status:", $status);

        return $text;
    }

    ###############################################################################
    # current advance
    ###############################################################################

    if ($cmd eq "advance") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my $advance = cm_advanceCurrent($data);

        return "No current advance defined"
            unless defined $advance;

        my $currency = $data->{settings}{currency} // 'EUR';
        my $text = "Current monthly advance
";
        $text .= "==============================
";
        $text .= sprintf("%-20s %s
", "Valid from:", $advance->{validFrom} // '');
        $text .= sprintf("%-20s %s
", "Valid to:", $advance->{validTo} // '');
        $text .= sprintf("%-20s %.2f %s
", "Amount:", $advance->{amount} // 0, $currency);
        $text .= sprintf("%-20s %s
", "Comment:", $advance->{comment} // '');

        return $text;
    }

    ###############################################################################
    # advance editor
    ###############################################################################

    if ($cmd eq "advanceEditor") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my $editor = $data->{advanceEditor};

        return "No advance editor active"
            unless ref($editor) eq 'HASH' && keys %{$editor};

        my $status = cm_advanceValidate($editor)
            ? 'ready to save'
            : 'incomplete';
        my $currency = $data->{settings}{currency} // 'EUR';

        my $text = "Advance editor
";
        $text .= "==============================
";
        $text .= sprintf("%-20s %s
", "Mode:", defined $editor->{_editId} ? 'edit' : 'new');
        $text .= sprintf("%-20s %s
", "Advance ID:", $editor->{_editId}) if defined $editor->{_editId};
        $text .= sprintf("%-20s %s
", "Valid from:", $editor->{validFrom} // '');
        $text .= sprintf("%-20s %.2f %s
", "Amount:", $editor->{amount} // 0, $currency);
        $text .= sprintf("%-20s %s
", "Comment:", $editor->{comment} // '');
        $text .= sprintf("%-20s %s
", "Status:", $status);

        return $text;
    }

    ###############################################################################
    # advance history
    ###############################################################################

    if ($cmd eq "advanceHistory") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        my $advances = $data->{advances};

        return "No advances defined"
            unless ref($advances) eq 'ARRAY' && @{$advances};

        my $currency = $data->{settings}{currency} // 'EUR';
        my $text = "Advance history
";
        $text .= "==============================
";

        for my $advance (@{$advances}) {
            next unless ref($advance) eq 'HASH';

            $text .= sprintf(
                "ID %s | %s - %s: %.2f %s/month",
                defined $advance->{id} ? $advance->{id} : '-',
                $advance->{validFrom} // '',
                ($advance->{validTo} // '') ne '' ? $advance->{validTo} : 'open',
                $advance->{amount} // 0,
                $currency
            );

            $text .= " (".($advance->{comment} // '').")"
                if defined $advance->{comment} && $advance->{comment} ne '';

            $text .= "
";
        }

        return $text;
    }

    ###############################################################################
    # Calendar-year billing
    ###############################################################################

    if ($cmd eq "billing") {
        my $sourceError = ConsumptionManager_SyncCounterSource($hash);
        return $sourceError if defined $sourceError;

        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;

        if (ConsumptionManager_SyncWastewaterBaselines($hash, $data)) {
            return "Unable to save inherited wastewater baseline"
                unless cm_coreSave($hash, $data);
        }

        my $result = cm_billingCalculate($data);
        return "Unable to calculate billing" unless defined $result;
        return "No counter available" if ($result->{status} // '') eq 'noCounter';
        return "No yearly baseline available. Use set ".$a[0]." yearBaseline ".cm_year()." <counter>"
            if ($result->{status} // '') eq 'noBaseline';
        return "Billing counter is below the yearly baseline (counter ".($result->{counterEnd} // '?').", baseline ".($result->{counterStart} // '?').")"
            if ($result->{status} // '') eq 'invalidCounterRange';
        return "No tariff defined for ".($result->{startDate} // '')
            if ($result->{status} // '') eq 'noTariff';
        if (($result->{status} // '') eq 'incomplete') {
            my $reason = ($result->{error} // '') eq 'inexactTariffSnapshot'
                ? 'inexact tariff snapshot'
                : 'missing tariff snapshot';
            return "Billing calculation incomplete: ".$reason." for ".($result->{tariffDate} // '');
        }

        my $currency   = $result->{currency} // ($data->{settings}{currency} // 'EUR');
        my $unitCounter = $result->{unitCounter} // '';
        my $unitBilling = $result->{unitBilling} // '';

        my $text = "Calendar-year billing
";
        $text .= "==============================
";
        $text .= sprintf("%-24s %s
", "Year:", $result->{year});
        $text .= sprintf("%-24s %s - %s
", "Period:", $result->{startDate}, $result->{endDate});
        $text .= sprintf("%-24s %s
", "Calculated to:", $result->{calculatedTo});
        $text .= sprintf("%-24s %.4f %s
", "Start counter:", $result->{baselineCounter}, $unitCounter);
        $text .= sprintf("%-24s %s
", "Baseline source:", $result->{baselineSource} // '');
        if (($hash->{MEDIUM} // '') eq 'wastewater') {
            my $currentTariff = cm_tariffCurrent($data);
            $text .= sprintf("%-24s %.4f %s
", "Fresh-water consumption:", $result->{counterConsumption}, $unitCounter);
            $text .= sprintf("%-24s %.2f %%
", "Assessment factor:", ($currentTariff->{assessmentFactor} // 1) * 100)
                if defined $currentTariff;
            $text .= sprintf("%-24s %.4f %s
", "Wastewater quantity:", $result->{billingConsumption}, $unitBilling);
        }
        else {
            $text .= sprintf("%-24s %.4f %s
", "Counter consumption:", $result->{counterConsumption}, $unitCounter);
            $text .= sprintf("%-24s %.4f %s
", "Billing consumption:", $result->{billingConsumption}, $unitBilling);
        }
        $text .= sprintf("%-24s %.2f %s
", "Work costs:", $result->{workCost}, $currency);
        $text .= sprintf("%-24s %.2f %s
", "Base costs:", $result->{baseCost}, $currency);
        if (($hash->{MEDIUM} // '') eq 'wastewater') {
            $text .= sprintf("%-28s %.2f %s
", "Surface usage fee:", $result->{surfaceUsageCost} // 0, $currency);
            $text .= sprintf("%-28s %.2f %s
", "Surface recurring fee:", $result->{surfaceRecurringCost} // 0, $currency);
            $text .= sprintf("%-28s %.2f %s
", "Surface drainage total:", $result->{surfaceCost} // 0, $currency);
        }
        $text .= sprintf("%-24s %.2f %s
", "Total costs:", $result->{totalCost}, $currency);
        $text .= sprintf("%-24s %.2f %s (%d)
", "Scheduled advances:", $result->{advanceAmount}, $currency, $result->{advanceCount});
        $text .= sprintf("%-24s %.2f %s
", "Financial reserve:", $result->{financialReserve}, $currency);
        $text .= sprintf("%-24s %s
", "Calculation exact:", $result->{exact} ? 'yes' : 'no');
        $text .= sprintf("%-24s %d
", "Tariff segments:", scalar @{ $result->{segments} // [] });

        for my $segment (@{ $result->{segments} // [] }) {
            $text .= sprintf(
                "  %s - %s: %.4f %s, %.2f %s (tariff %s)
",
                $segment->{startDate} // '',
                $segment->{endDate} // '',
                $segment->{counterConsumption} // 0,
                $unitCounter,
                $segment->{totalCost} // 0,
                $currency,
                defined $segment->{tariffId} ? $segment->{tariffId} : '-'
            );
        }
        return $text;
    }

    ###############################################################################
    # cost
    ###############################################################################

    if ($cmd eq "cost") {
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;

        my $tariff = cm_tariffCurrent($data);
        return "No current tariff defined" unless defined $tariff;

        my $today = cm_billingCalculatePeriod($data, 'today');
        my $month = cm_billingCalculatePeriod($data, 'month');
        my $year  = cm_billingCalculatePeriod($data, 'year');

        my @periods = (
            [ "Today",      $today, cm_costToday($data, $tariff) ],
            [ "Yesterday",  undef,  cm_costYesterday($data, $tariff) ],
            [ "Month",      $month, cm_costMonth($data, $tariff) ],
            [ "Last month", undef,  cm_costLastMonth($data, $tariff) ],
            [ "Year",       $year,  cm_costYear($data, $tariff) ],
            [ "Last year",  undef,  cm_costLastYear($data, $tariff) ],
        );

        my $currency = $tariff->{currency} // "EUR";
        my $text = "Current costs\n";
        $text .= "==============================\n";

        for my $period (@periods) {
            my ($label, $multi, $legacy) = @{$period};
            my $value;

            if (ref($multi) eq 'HASH' && ($multi->{status} // '') eq 'active') {
                $value = $multi->{totalCost};
            }
            elsif (ref($multi) eq 'HASH' && ($multi->{status} // '') eq 'incomplete') {
                return "Cost calculation incomplete for $label: tariff snapshot required for ".($multi->{tariffDate} // '');
            }
            else {
                return "Unable to calculate costs" unless defined $legacy;
                $value = $legacy->{total};
            }

            $text .= sprintf("%-20s %.2f %s\n", $label . ":", $value, $currency);
        }

        return $text;
    }

    return "Unknown argument $cmd, choose one of counter monthBaseline yearBaseline meterChanges tariff tariffHistory tariffEditor advance advanceEditor advanceHistory billing cost";
}

###############################################################################
# Synchronize the configured counter source on demand. Derived wastewater
# devices can be created after the water device already has a virtualCounter;
# in that case no new event may arrive immediately, so seed the local meter
# from the existing source reading before billing.
###############################################################################

sub ConsumptionManager_SyncCounterSource {
    my ($hash) = @_;

    return undef unless defined $hash && ref($hash) eq 'HASH';

    my $counterDevice  = AttrVal($hash->{NAME}, 'counterDevice', '');
    my $counterReading = AttrVal($hash->{NAME}, 'counterReading', '');
    return undef if $counterDevice eq '' || $counterReading eq '';

    my $rawValue = ReadingsVal($counterDevice, $counterReading, undef);
    return undef unless defined $rawValue;

    my $multiplier = AttrVal($hash->{NAME}, 'counterMultiplier', 1);
    return 'Invalid counter source value or multiplier'
        unless $rawValue =~ /^\d+(?:\.\d+)?$/
        && $multiplier =~ /^\d+(?:\.\d+)?$/
        && $multiplier > 0;

    my $data = cm_coreLoad($hash);
    return 'Unable to load storage' unless $data;
    return undef if defined $data->{meter}{current};

    my $value = ($rawValue + 0) * ($multiplier + 0);
    my $counterDecimals = ConsumptionManager_EffectiveCounterDecimals(
        $rawValue,
        $multiplier
    );
    return ConsumptionManager_ProcessCounterValue(
        $hash,
        $value,
        $counterDecimals
    );
}

###############################################################################
# Synchronize wastewater yearly baselines from a linked water ConsumptionManager.
# Wastewater reads the water device's virtualCounter, therefore its baseline must
# use the same virtual counter scale. This also automatically includes meter
# changes that occurred before the beginning of a year.
###############################################################################

sub ConsumptionManager_SyncWastewaterBaselines {
    my ($hash, $data) = @_;

    return 0 unless defined $hash && ref($hash) eq 'HASH';
    return 0 unless defined $data && ref($data) eq 'HASH';
    return 0 unless (($hash->{MEDIUM} // '') eq 'wastewater');

    my $sourceName = AttrVal($hash->{NAME}, 'counterDevice', '');
    return 0 if $sourceName eq '';
    return 0 unless defined $defs{$sourceName};

    my $sourceHash = $defs{$sourceName};
    return 0 unless (($sourceHash->{TYPE} // '') eq 'ConsumptionManager');
    return 0 unless (($sourceHash->{MEDIUM} // '') eq 'water');

    my $sourceData = cm_coreLoad($sourceHash);
    return 0 unless defined $sourceData && ref($sourceData) eq 'HASH';

    $data->{consumption} ||= {};
    my $source = $sourceData->{consumption} // {};
    my $target = $data->{consumption};
    my $changed = 0;

    # Wastewater reads Water:virtualCounter, so all inherited baselines are
    # already on exactly the same virtual counter scale. No second offset is
    # applied here.
    for my $spec (
        [ 'dayKey',   'dayBaseline'   ],
        [ 'monthKey', 'monthBaseline' ],
        [ 'yearKey',  'yearBaseline'  ],
    ) {
        my ($keyField, $baselineField) = @{$spec};
        next unless defined $source->{$keyField} && $source->{$keyField} ne '';
        next unless defined $source->{$baselineField};

        if (($target->{$keyField} // '') ne $source->{$keyField}
            || !defined($target->{$baselineField})
            || abs(($target->{$baselineField} // 0) - $source->{$baselineField}) > 0.0000001) {
            $target->{$keyField}      = $source->{$keyField};
            $target->{$baselineField} = 0 + $source->{$baselineField};
            $changed = 1;
        }
    }

    # Previous-period values are copied as well so wastewater exposes the same
    # six consumption periods as its source water device.
    for my $field (qw(yesterday lastMonthValue lastYearValue)) {
        next unless defined $source->{$field};
        if (!defined($target->{$field})
            || abs(($target->{$field} // 0) - $source->{$field}) > 0.0000001) {
            $target->{$field} = 0 + $source->{$field};
            $changed = 1;
        }
    }

    return $changed;
}

#####################################
sub ConsumptionManager_Attr(@)
{
    my ($cmd, $name, $attrName, $attrValue) = @_;

    my $hash = $defs{$name};

    return undef unless defined $hash;

    if ($attrName eq "counterMultiplier" && $cmd eq "set") {
        return "counterMultiplier must be a positive number"
            unless defined $attrValue
            && $attrValue =~ /^\d+(?:\.\d+)?$/
            && $attrValue > 0;
    }

    if ($attrName eq "consumptionDecimals" && $cmd eq "set") {
        return "consumptionDecimals must be an integer between 0 and 9"
            unless defined $attrValue
            && $attrValue =~ /^\d+$/
            && $attrValue >= 0
            && $attrValue <= 9;
    }

    if ($attrName eq "powerTimeout" && $cmd eq "set") {
        return "powerTimeout must be a non-negative integer"
            unless defined $attrValue
            && $attrValue =~ /^\d+$/;
    }

    if ($attrName eq "counterDevice") {
        $hash->{NOTIFYDEV} = $cmd eq "set"
            ? $attrValue
            : "global";
    }

    return undef;
}

###############################################################################
# Process reading events from the configured counter device
###############################################################################

sub ConsumptionManager_Notify($$)
{
    my ($hash, $dev) = @_;

    return undef unless defined $hash;
    return undef unless defined $dev;
    return undef if AttrVal($hash->{NAME}, "disable", 0);

    my $counterDevice = AttrVal(
        $hash->{NAME},
        "counterDevice",
        ""
    );

    my $counterReading = AttrVal(
        $hash->{NAME},
        "counterReading",
        ""
    );

    return undef unless $counterDevice ne "";
    return undef unless $counterReading ne "";
    return undef unless defined $dev->{NAME};
    return undef unless $dev->{NAME} eq $counterDevice;

    my $events = deviceEvents($dev, 1);

    return undef unless defined $events;

    my $readingChanged = 0;

    foreach my $event (@{$events}) {
        next unless defined $event;

        if ($event =~ /^\Q$counterReading\E:\s*/) {
            $readingChanged = 1;
            last;
        }
    }

    return undef unless $readingChanged;

    my $rawValue = ReadingsVal(
        $counterDevice,
        $counterReading,
        undef
    );

    return undef unless defined $rawValue;

    my $multiplier = AttrVal(
        $hash->{NAME},
        "counterMultiplier",
        1
    );

    unless (
           $rawValue =~ /^\d+(?:\.\d+)?$/
        && $multiplier =~ /^\d+(?:\.\d+)?$/
        && $multiplier > 0
    ) {
        Log3(
            $hash,
            3,
            $hash->{NAME}.": Invalid counter source value or multiplier"
        );

        return undef;
    }

    my $value = ($rawValue + 0) * ($multiplier + 0);
    my $counterDecimals = ConsumptionManager_EffectiveCounterDecimals(
        $rawValue,
        $multiplier
    );

    my $error = ConsumptionManager_ProcessCounterValue(
        $hash,
        $value,
        $counterDecimals
    );

    Log3(
        $hash,
        3,
        $hash->{NAME}.": Unable to process counter source: ".$error
    ) if defined $error;

    return undef;
}

###############################################################################
# Decimal precision helpers
###############################################################################

sub ConsumptionManager_DecimalPlaces {
    my ($value, $trimTrailingZeros) = @_;

    return 0 unless defined $value;
    my $text = "$value";
    return 0 unless $text =~ /^\d+(?:\.(\d+))?$/;

    my $fraction = defined $1 ? $1 : '';
    $fraction =~ s/0+$// if $trimTrailingZeros;
    return length($fraction);
}

sub ConsumptionManager_EffectiveCounterDecimals {
    my ($rawValue, $multiplier) = @_;

    my $rawDecimals = ConsumptionManager_DecimalPlaces($rawValue, 0);
    my $multiplierDecimals = ConsumptionManager_DecimalPlaces($multiplier, 1);
    my $decimals = $rawDecimals + $multiplierDecimals;

    return $decimals > 9 ? 9 : $decimals;
}

sub ConsumptionManager_ConsumptionDecimals {
    my ($hash, $data) = @_;

    # Explicit user configuration always wins.
    my $configured = AttrVal($hash->{NAME}, 'consumptionDecimals', '');
    return 0 + $configured
        if defined $configured && $configured =~ /^\d+$/ && $configured <= 9;

    # Prefer the currently configured source reading.  This also fixes
    # existing devices directly after an update, even if no new source
    # event has arrived yet and meter.counterDecimals has not been stored.
    my $counterDevice  = AttrVal($hash->{NAME}, 'counterDevice', '');
    my $counterReading = AttrVal($hash->{NAME}, 'counterReading', '');

    if ($counterDevice ne '' && $counterReading ne '') {
        my $rawValue = ReadingsVal($counterDevice, $counterReading, undef);
        my $multiplier = AttrVal($hash->{NAME}, 'counterMultiplier', 1);

        if (defined $rawValue
            && $rawValue =~ /^\d+(?:\.\d+)?$/
            && defined $multiplier
            && $multiplier =~ /^\d+(?:\.\d+)?$/
            && $multiplier > 0) {

            return ConsumptionManager_EffectiveCounterDecimals(
                $rawValue,
                $multiplier
            );
        }
    }

    # Precision learned from previous live counter updates.
    return 0 + $data->{meter}{counterDecimals}
        if ref($data->{meter}) eq 'HASH'
        && defined $data->{meter}{counterDecimals}
        && $data->{meter}{counterDecimals} =~ /^\d+$/
        && $data->{meter}{counterDecimals} <= 9;

    # Migration/fallback for existing devices: infer from the stored physical
    # counter rather than falling back immediately to the historical default 3.
    if (ref($data->{meter}) eq 'HASH'
        && defined $data->{meter}{current}
        && $data->{meter}{current} =~ /^\d+(?:\.\d+)?$/) {

        return ConsumptionManager_DecimalPlaces(
            $data->{meter}{current},
            0
        );
    }

    return 3;
}

###############################################################################
# Store a counter value and refresh readings/timer
###############################################################################

sub ConsumptionManager_ProcessCounterValue {
    my ($hash, $value, $counterDecimals) = @_;

    return "Invalid value"
        unless defined $value
        && $value =~ /^\d+(?:\.\d+)?$/;

    return "Unable to save counter"
        unless cm_coreSetCounter($hash, $value, $counterDecimals);

    ConsumptionManager_UpdateReadings($hash);

    RemoveInternalTimer($hash);

    my $timeout = AttrVal(
        $hash->{NAME},
        "powerTimeout",
        CM_DEFAULT_POWER_TIMEOUT
    );

    if ($timeout > 0) {
        InternalTimer(
            gettimeofday() + $timeout,
            "ConsumptionManager_PowerTimeout",
            $hash,
            0
        );
    }

    return undef;
}

###############################################################################
sub ConsumptionManager_UpdateReadings {
    my ($hash) = @_;

    my $data = cm_coreLoad($hash);

    return unless $data;

    if (ConsumptionManager_SyncWastewaterBaselines($hash, $data)) {
        cm_coreSave($hash, $data);
    }

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

    if (defined $data->{meter}{virtual}) {
        readingsBulkUpdate(
            $hash,
            "virtualCounter",
            $data->{meter}{virtual}
        );
    }

    if (defined $data->{meter}{powerCurrent}) {
        readingsBulkUpdate(
            $hash,
            "powerCurrent",
            $data->{meter}{powerCurrent}
        );
    }

    my $consumptionDecimals = ConsumptionManager_ConsumptionDecimals($hash, $data);
    my $consumptionFormat = "%.${consumptionDecimals}f";

    readingsBulkUpdate(
        $hash,
        "consumptionToday",
        sprintf($consumptionFormat, cm_consumptionToday($data))
    );

    readingsBulkUpdate(
        $hash,
        "consumptionMonth",
        sprintf($consumptionFormat, cm_consumptionMonth($data))
    );

    readingsBulkUpdate(
        $hash,
        "consumptionYear",
        sprintf($consumptionFormat, cm_consumptionYear($data))
    );

    readingsBulkUpdate(
        $hash,
        "consumptionYesterday",
        sprintf($consumptionFormat, cm_consumptionYesterday($data))
    );

    readingsBulkUpdate(
        $hash,
        "consumptionLastMonth",
        sprintf($consumptionFormat, cm_consumptionLastMonth($data))
    );

    readingsBulkUpdate(
        $hash,
        "consumptionLastYear",
        sprintf($consumptionFormat, cm_consumptionLastYear($data))
    );

    # Gas meters measure volume in m3, while billing is based on energy in kWh.
    # Keep the six consumption readings in the physical meter unit and expose
    # the corresponding tariff-aware energy values separately.
    if (($hash->{MEDIUM} // '') eq 'gas') {
        my @energyPeriods = (
            [ "energyToday",     cm_consumptionToday($data),     cm_billingCalculatePeriod($data, 'today') ],
            [ "energyYesterday", cm_consumptionYesterday($data), cm_billingCalculatePreviousPeriod($data, 'yesterday') ],
            [ "energyMonth",     cm_consumptionMonth($data),     cm_billingCalculatePeriod($data, 'month') ],
            [ "energyLastMonth", cm_consumptionLastMonth($data), cm_billingCalculatePreviousPeriod($data, 'lastMonth') ],
            [ "energyYear",      cm_consumptionYear($data),      cm_billingCalculatePeriod($data, 'year') ],
            [ "energyLastYear",  cm_consumptionLastYear($data),  cm_billingCalculatePreviousPeriod($data, 'lastYear') ],
        );

        for my $entry (@energyPeriods) {
            my ($reading, $counterConsumption, $result) = @{$entry};

            # A missing completed period is represented by the compact
            # consumption layer as zero. Keep all six gas energy readings
            # present in that case instead of silently omitting the reading.
            if (defined($counterConsumption) && $counterConsumption == 0) {
                readingsBulkUpdate(
                    $hash,
                    $reading,
                    sprintf($consumptionFormat, 0)
                );
                next;
            }

            # For a real consumption > 0, never invent an energy value.
            # Missing/inexact tariff data remains visible as a calculation
            # problem rather than being disguised as zero consumption.
            next unless ref($result) eq 'HASH';
            next unless ($result->{status} // '') eq 'active';
            next unless defined $result->{billingConsumption};

            readingsBulkUpdate(
                $hash,
                $reading,
                sprintf($consumptionFormat, $result->{billingConsumption})
            );
        }
    }

    my $tariff = cm_tariffCurrent($data);

    if (defined $tariff) {
        my $todayCost = cm_billingCalculatePeriod($data, 'today');
        my $monthCost = cm_billingCalculatePeriod($data, 'month');
        my $yearCost  = cm_billingCalculatePeriod($data, 'year');

        my @costReadings = (
            [ "costToday",     $todayCost, cm_costToday($data, $tariff) ],
            [ "costYesterday", undef,      cm_costYesterday($data, $tariff) ],
            [ "costMonth",     $monthCost, cm_costMonth($data, $tariff) ],
            [ "costLastMonth", undef,      cm_costLastMonth($data, $tariff) ],
            [ "costYear",      $yearCost,  cm_costYear($data, $tariff) ],
            [ "costLastYear",  undef,      cm_costLastYear($data, $tariff) ],
        );

        for my $entry (@costReadings) {
            my ($reading, $multi, $legacy) = @{$entry};
            my $value;

            if (ref($multi) eq 'HASH' && ($multi->{status} // '') eq 'active') {
                $value = $multi->{totalCost};
            }
            elsif (defined $legacy) {
                $value = $legacy->{total};
            }
            else {
                next;
            }

            readingsBulkUpdate($hash, $reading, sprintf("%.2f", $value));
        }
    }

    my $advance = cm_advanceCurrent($data);

    if (defined $advance) {
        readingsBulkUpdate(
            $hash,
            "advanceCurrent",
            sprintf("%.2f", $advance->{amount} // 0)
        );
    }

    my $billingResult = cm_billingCalculate($data);

    if (defined $billingResult && ($billingResult->{status} // '') eq 'active') {
        readingsBulkUpdate($hash, "billingConsumption", sprintf("%.3f", $billingResult->{counterConsumption}));
        readingsBulkUpdate($hash, "billingWorkCost", sprintf("%.2f", $billingResult->{workCost}));
        readingsBulkUpdate($hash, "billingBaseCost", sprintf("%.2f", $billingResult->{baseCost}));
        if (($hash->{MEDIUM} // '') eq 'wastewater') {
            readingsBulkUpdate($hash, "billingSurfaceUsageCost", sprintf("%.2f", $billingResult->{surfaceUsageCost} // 0));
            readingsBulkUpdate($hash, "billingSurfaceRecurringCost", sprintf("%.2f", $billingResult->{surfaceRecurringCost} // 0));
            readingsBulkUpdate($hash, "billingSurfaceCost", sprintf("%.2f", $billingResult->{surfaceCost} // 0));
        }
        readingsBulkUpdate($hash, "billingCost", sprintf("%.2f", $billingResult->{totalCost}));
        readingsBulkUpdate($hash, "advanceScheduled", sprintf("%.2f", $billingResult->{advanceAmount}));
        readingsBulkUpdate($hash, "financialReserve", sprintf("%.2f", $billingResult->{financialReserve}));
    }

    my $currentMonth = cm_month();
    if (($data->{consumption}{monthKey} // '') eq $currentMonth
        && defined $data->{consumption}{monthBaseline}) {
        readingsBulkUpdate($hash, "monthBaseline", $data->{consumption}{monthBaseline});
    }

    my $currentYear = cm_year();
    if (($data->{consumption}{yearKey} // '') eq $currentYear
        && defined $data->{consumption}{yearBaseline}) {
        readingsBulkUpdate($hash, "yearBaseline", $data->{consumption}{yearBaseline});
    }

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
# Build the dynamic FHEMWEB set command list
###############################################################################

sub ConsumptionManager_SetList {

    my ($hash, $unknown) = @_;

    my @commands = (
        'counter',
        'monthBaseline',
        'yearBaseline',
    );

    push @commands, 'meterChange'
        unless (($hash->{MEDIUM} // '') eq 'wastewater');

    my $data = cm_coreLoad($hash);
    my $editorActive =
           $data
        && ref($data->{tariffEditor}) eq 'HASH'
        && keys %{ $data->{tariffEditor} };

    my $advanceEditorActive =
           $data
        && ref($data->{advanceEditor}) eq 'HASH'
        && keys %{ $data->{advanceEditor} };

    if ($editorActive) {
        push @commands,
            'tariffValidFrom',
            'tariffWorkPrice',
            'tariffBasePrice',
            'tariffBasePriceUnit:month,year',
            'tariffCurrency:EUR',
            'tariffComment',
            'tariffCounterSnapshot',
            'tariffSave:noArg',
            'tariffCancel:noArg';

        if (($hash->{MEDIUM} // '') eq 'gas') {
            push @commands,
                'tariffCalorificValue',
                'tariffStateNumber';
        }
        elsif (($hash->{MEDIUM} // '') eq 'wastewater') {
            push @commands,
                'tariffAssessmentFactor',
                'tariffSurfaceUsageArea',
                'tariffSurfaceUsagePrice',
                'tariffSurfaceRecurringArea',
                'tariffSurfaceRecurringPrice';
        }
    }
    else {
        push @commands, 'tariffCreate:noArg', 'tariffEdit';
    }

    if ($advanceEditorActive) {
        push @commands,
            'advanceValidFrom',
            'advanceValidTo',
            'advanceAmount',
            'advanceComment',
            'advanceSave:noArg',
            'advanceCancel:noArg';
    }
    else {
        push @commands, 'advanceCreate:noArg', 'advanceEdit';
    }

    return 'Unknown argument '
        . ($unknown // '')
        . ', choose one of '
        . join(' ', @commands);
}

###############################################################################
# Tariff commands
###############################################################################

sub ConsumptionManager_SetTariff {
    my ($hash, $action, @values) = @_;

    return "Unknown tariff command"
        unless defined $action;

    my $data = cm_coreLoad($hash);

    return "Unable to load storage"
        unless $data;

    if ($action eq 'create') {
        return "Unable to create tariff"
            unless cm_tariffCreate($hash, $data);
    }
    elsif ($action eq 'edit') {
        return "Missing tariff ID" unless @values;
        return "Unable to load tariff into editor"
            unless cm_tariffEdit($data, $values[0]);
    }
    elsif ($action eq 'save') {
        return "Unable to save tariff"
            unless cm_tariffSave($data);
    }
    elsif ($action eq 'cancel') {
        return "Unable to cancel tariff editor"
            unless cm_tariffCancel($data);
    }
    else {
        return "Missing tariff value"
            unless @values;

        my $value = $action eq 'comment'
            ? join(' ', @values)
            : $values[0];

        return "Invalid tariff value"
            unless cm_tariffSetValue(
                $data,
                $action,
                $value
            );
    }

    return "Unable to save storage"
        unless cm_coreSave($hash, $data);

    ConsumptionManager_UpdateReadings($hash)
        if $action eq 'save';

    return undef;
}

1;

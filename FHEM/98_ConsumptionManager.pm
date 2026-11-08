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
use JSON::PP ();
use POSIX qw(mktime);


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
    cm_coreSetBoundary
    cm_coreRegisterMeterChange
);

use ConsumptionManager::Meter qw(cm_meterEditChange);

use ConsumptionManager::CounterHistory qw(cm_counterHistoryCalculateCurrent cm_counterHistoryCalculateRange);

use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionYesterday
    cm_consumptionMonth
    cm_consumptionLastMonth
    cm_consumptionYear
    cm_consumptionLastYear
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
    cm_billingCalculatePhysicalPeriod
    cm_billingCalculatePhysicalYear
    cm_billingCalculatePhysicalBillingYear
);

use ConsumptionManager::Utils qw(
    cm_dateKeys
    cm_year
    cm_month
);

our $VERSION = CM_VERSION;
our $readingFnAttributes;
our %defs;
our %modules;
our %attr;
our $FW_CSRF;

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
    $hash->{FW_detailFn} = 'ConsumptionManager_FWDetail';

    $hash->{AttrList} =
          'alias'
        . ' room'
        . ' group'
        . ' disable:0,1'
        . ' currentTimeout'
        . ' counterDevice'
        . ' counterReading'
        . ' counterMultiplier'
        . ' consumptionDecimals'
        . ' billingYearStart:01,02,03,04,05,06,07,08,09,10,11,12'
        . ' dailyHistoryDays'
        . ' monthlyHistoryMonths'
        . ' yearlyHistoryYears'
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
    # FHEMWEB uses the device-specific list installed by setDevAttrList.
    # Preserve all standard module attributes and specialize only the units.
    my $unitChoices = $medium eq 'electricity' ? 'Wh,kWh' : 'm3,l';
    my $deviceAttrList = $modules{ConsumptionManager}{AttrList} // '';
    $deviceAttrList .= ' consumptionUnit:' . $unitChoices;
    $deviceAttrList .= ' powerUnit:kW,W'
        if $medium eq 'electricity' || $medium eq 'gas';
    $deviceAttrList .= ' flowUnit:m3/h,l/h'
        if $medium eq 'gas' || $medium eq 'water';
    setDevAttrList($hash->{NAME}, $deviceAttrList);
    $hash->{NOTIFYDEV} = 'global,' . AttrVal($hash->{NAME}, 'counterDevice', '');

    cm_coreInitializeDevice($hash, $medium);

    ConsumptionManager_CaptureMidnight($hash, undef, 'estimatedAfterRestart');
    ConsumptionManager_UpdateReadings($hash);
    ConsumptionManager_ScheduleMidnight($hash);

    return undef;
}

sub ConsumptionManager_Undef($)
{
    my ($hash, $arg) = @_;

    RemoveInternalTimer($hash);
    RemoveInternalTimer($hash->{helper}{cmMidnightTimer})
        if ref($hash->{helper}{cmMidnightTimer}) eq 'HASH';

    return undef;
}

#####################################
sub ConsumptionManager_Set($@)
{
    my ($hash, @a) = @_;

    return "Need at least one argument"
        if (@a < 2);

    my $cmd = $a[1];

    # One atomic update from the FHEMWEB tariff form. All changes are applied
    # to a detached copy and persisted only after the full tariff validates.
    if ($cmd eq 'tariffApply') {
        return "Usage: set ".$a[0]." tariffApply <new|id> <json>"
            if @a < 4;
        my $mode = $a[2];
        return "Invalid tariff ID" unless $mode eq 'new' || $mode =~ /^\d+$/;
        my $values = eval { JSON::PP->new->decode(join(' ', @a[3..$#a])) };
        return "Invalid tariff form data" if $@ || ref($values) ne 'HASH';
        my %allowed = map { $_ => 1 } qw(validFrom workPrice basePrice
            basePriceUnit currency calorificValue stateNumber assessmentFactor
            surfaceUsageArea surfaceUsagePrice surfaceRecurringArea
            surfaceRecurringPrice comment);
        return "Invalid tariff field" if grep { !$allowed{$_} } keys %$values;
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;
        my $copy = eval { JSON::PP->new->decode(JSON::PP->new->encode($data)) };
        return "Unable to copy storage" if $@ || ref($copy) ne 'HASH';
        my $ok = $mode eq 'new'
            ? cm_tariffCreate($hash, $copy)
            : cm_tariffEdit($copy, $mode);
        return "Unable to initialize tariff" unless $ok;
        for my $field (sort keys %$values) {
            return "Invalid value for ".$field
                unless cm_tariffSetValue($copy, $field, $values->{$field});
        }
        return "Unable to save tariff (check validity date and values)"
            unless cm_tariffSave($copy);
        return "Unable to save storage" unless cm_coreSave($hash, $copy);
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    # Atomic FHEMWEB form for monthly advances. Work on a detached copy so
    # invalid dates or amounts cannot alter the persisted advance history.
    if ($cmd eq 'advanceApply') {
        return "Usage: set ".$a[0]." advanceApply <new|id> <json>"
            if @a < 4;
        my $mode = $a[2];
        return "Invalid advance ID" unless $mode eq 'new' || $mode =~ /^\d+$/;
        my $values = eval { JSON::PP->new->decode(join(' ', @a[3..$#a])) };
        return "Invalid advance form data" if $@ || ref($values) ne 'HASH';
        my %allowed = map { $_ => 1 } qw(validFrom validTo amount comment);
        return "Invalid advance field" if grep { !$allowed{$_} } keys %$values;
        for my $required (qw(validFrom amount)) {
            return "Missing advance field ".$required unless exists $values->{$required};
        }
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;
        my $copy = eval { JSON::PP->new->decode(JSON::PP->new->encode($data)) };
        return "Unable to copy storage" if $@ || ref($copy) ne 'HASH';
        my $ok = $mode eq 'new'
            ? cm_advanceCreate($copy)
            : cm_advanceEdit($copy, $mode);
        return "Unable to initialize advance" unless $ok;
        for my $field (sort keys %$values) {
            return "Invalid value for ".$field
                unless cm_advanceSetValue($copy, $field, $values->{$field});
        }
        return "Unable to save advance (check validity dates and amount)"
            unless cm_advanceSave($copy);
        return "Unable to save storage" unless cm_coreSave($hash, $copy);
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    # Atomic FHEMWEB form for a physical meter replacement.
    if ($cmd eq 'meterChangeApply') {
        return "Meter changes are managed on the water device"
            if ($hash->{MEDIUM} // '') eq 'wastewater';
        return "Usage: set ".$a[0]." meterChangeApply <json>" if @a < 3;
        my $values = eval { JSON::PP->new->decode(join(' ', @a[2..$#a])) };
        return "Invalid meter change data" if $@ || ref($values) ne 'HASH';
        my %allowed = map { $_ => 1 } qw(date oldCounter newCounter comment);
        return "Invalid meter change field"
            if grep { !$allowed{$_} } keys %$values;
        my ($date, $old, $new) = @{$values}{qw(date oldCounter newCounter)};
        return "Invalid date" unless defined $date
            && $date =~ /^\d{4}-\d{2}-\d{2}$/;
        return "Invalid old counter" unless defined $old
            && $old =~ /^\d+(?:\.\d+)?$/;
        return "Invalid new counter" unless defined $new
            && $new =~ /^\d+(?:\.\d+)?$/;
        return "Unable to save meter change"
            unless cm_coreRegisterMeterChange($hash, $date, $old, $new,
                $values->{comment} // '');
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    if ($cmd eq 'meterChangeEdit') {
        return "Meter changes are managed on the water device"
            if ($hash->{MEDIUM} // '') eq 'wastewater';
        return "Usage: set ".$a[0]." meterChangeEdit <index> <date> <oldCounter> <newCounter> [HH:MM[:SS]] [comment]"
            if @a < 6;
        my ($index, $date, $old, $new) = @a[2..5];
        my @tail = @a > 6 ? @a[6..$#a] : ();
        my $effectiveAt;
        if (@tail && $tail[0] =~ /^(\d{2}:\d{2})(?::(\d{2}))?$/) {
            my $clock = shift @tail;
            $clock .= ':00' if $clock =~ /^\d{2}:\d{2}$/;
            $effectiveAt = "$date $clock";
        }
        my $comment = join(' ', @tail);
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;
        my $copy = eval { JSON::PP->new->decode(JSON::PP->new->encode($data)) };
        return "Unable to copy storage" if $@ || ref($copy) ne 'HASH';
        return "Unable to correct meter change (check values and chronological order)"
            unless cm_meterEditChange($copy, $index, $date, $old, $new, $comment, $effectiveAt);
        return "Unable to save storage" unless cm_coreSave($hash, $copy);
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    if ($cmd eq "counter") {
        return "Wastewater uses the linked water device counter"
            if ($hash->{MEDIUM} // "") eq "wastewater";

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

    # User-controlled retention protection for any physical snapshot.
    if ($cmd eq 'counterDelete') {
        return 'Counter history is managed on the water device'
            if ($hash->{MEDIUM} // '') eq 'wastewater';
        return 'Usage: set '.$a[0].' counterDelete <YYYY-MM-DD>'
            unless @a == 3 && $a[2] =~ /^\d{4}-\d{2}-\d{2}$/;
        my $data = cm_coreLoad($hash);
        return 'Unable to load storage' unless $data;
        my @matches = grep { ref($_) eq 'HASH' && ($_->{date} // '') eq $a[2] }
            @{ $data->{counterHistory} // [] };
        return 'Only one manual snapshot can be deleted'
            unless @matches == 1 && ($matches[0]{source} // '') eq 'manual';
        $data->{counterHistory} = [
            grep { !(ref($_) eq 'HASH' && ($_->{date} // '') eq $a[2]) }
                @{ $data->{counterHistory} }
        ];
        return 'Unable to save history' unless cm_coreSave($hash, $data);
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    if ($cmd eq "counterBoundary") {
        return "Physical midnight boundaries are managed on the water device"
            if ($hash->{MEDIUM} // '') eq 'wastewater';
        return "Usage: set ".$a[0]." counterBoundary <YYYY-MM-DD> <counter>"
            unless @a == 4;
        my ($date, $counter) = @a[2, 3];
        my $existingData = cm_coreLoad($hash);
        return 'Unable to load storage' unless $existingData;
        my @existing = grep { ref($_) eq 'HASH' && ($_->{date} // '') eq $date }
            @{ $existingData->{counterHistory} // [] };
        return 'Automatic snapshots cannot be edited'
            if @existing && (@existing != 1 || ($existing[0]{source} // '') ne 'manual');
        return "Invalid physical midnight boundary"
            unless defined($date) && $date =~ /^\d{4}-\d{2}-\d{2}$/
                && defined($counter) && $counter =~ /^\d+(?:\.\d+)?$/;
        return "Unable to save physical midnight boundary"
            unless cm_coreSetBoundary($hash, $date, $counter);
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    ###############################################################################

    if ($cmd eq "meterChange") {

        return "Meter changes are managed on the water device"
            if ($hash->{MEDIUM} // '') eq 'wastewater';

        return "Usage: set ".$a[0]." meterChange <YYYY-MM-DD> <oldCounter> <newCounter> [HH:MM[:SS]] [comment]"
            if (@a < 5);

        my ($date, $oldCounter, $newCounter) = @a[2, 3, 4];
        my @tail = @a > 5 ? @a[5 .. $#a] : ();
        my $effectiveAt;
        if (@tail && $tail[0] =~ /^\d{2}:\d{2}(?::\d{2})?$/) {
            my $clock = shift @tail;
            $clock .= ':00' if $clock =~ /^\d{2}:\d{2}$/;
            $effectiveAt = "$date $clock";
        }
        my $comment = join(" ", @tail);

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
                $comment,
                $effectiveAt
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

    ###############################################################################
    # counterHistory (physical midnight counter snapshots)
    ###############################################################################
    if ($cmd eq "counterHistory") {
        return "Usage: get ".$a[0]." counterHistory" if @a > 2;

        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;

        ConsumptionManager_SyncWastewaterBaselines($hash, $data);
        my $history = $data->{counterHistory};
        return "No counter history stored"
            unless ref($history) eq 'ARRAY' && @{$history};

        my $text = "Physical counter history\n";
        $text .= "==============================\n";

        for my $entry (sort {
            ($a->{boundary} // $a->{date} // '') cmp
            ($b->{boundary} // $b->{date} // '')
        } grep { ref($_) eq 'HASH' } @{$history}) {
            $text .= sprintf(
                "%s | counter %s | observed %s | captured %s | source %s | kinds %s\n",
                $entry->{boundary} // $entry->{date} // '',
                defined $entry->{counter} ? $entry->{counter} : 'n/a',
                $entry->{observedAt} // '',
                $entry->{capturedAt} // '',
                $entry->{source} // '',
                ref($entry->{kinds}) eq 'ARRAY' ? join(',', @{$entry->{kinds}}) : ''
            );
        }
        return $text;
    }

    ###############################################################################
    # Physical midnight boundaries are listed by counterHistory.
    ###############################################################################

    if ($cmd eq "meterChanges") {

        my $data = cm_coreLoad($hash);

        return "Unable to load storage"
            unless $data;

        ConsumptionManager_SyncWastewaterBaselines($hash, $data);
        my $changes = $data->{meterChanges};

        return "No meter changes defined"
            unless ref($changes) eq 'ARRAY' && @{$changes};

        my $text = "Meter changes\n";
        $text .= "==============================\n";

        for my $change (@{$changes}) {
            $text .= sprintf(
                "%s: %.6f -> %.6f",
                $change->{effectiveAt} // $change->{date} // '',
                $change->{oldCounter} // 0,
                $change->{newCounter} // 0
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

    if ($cmd eq "billing" || $cmd eq "overview") {
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;
        ConsumptionManager_SyncWastewaterBaselines($hash, $data);
        my $billingMonth = AttrVal($hash->{NAME}, 'billingYearStart', '01');
        my $result = cm_billingCalculatePhysicalBillingYear($data, $billingMonth);
        return "Unable to calculate physical billing" unless ref($result) eq 'HASH';
        return "Physical billing incomplete: " . ($result->{error} // $result->{status} // 'unknown')
            unless ($result->{status} // '') eq 'active';
        my $currency = $data->{settings}{currency} // 'EUR';
        my $text = "Physical billing year (start month $billingMonth)\n";
        $text .= "==============================\n";
        $text .= sprintf("Period: %s - %s\n", $result->{startDate}, $result->{calculatedTo});
        $text .= sprintf("Meter consumption: %.4f\n", $result->{counterConsumption});
        $text .= sprintf("Billing consumption: %.4f\n", $result->{billingConsumption});
        $text .= sprintf("Work costs: %.2f %s\n", $result->{workCost}, $currency);
        $text .= sprintf("Base costs: %.2f %s\n", $result->{baseCost}, $currency);
        if (($hash->{MEDIUM} // '') eq 'wastewater') {
            $text .= sprintf("Surface usage: %.2f %s\n", $result->{surfaceUsageCost}, $currency);
            $text .= sprintf("Surface recurring: %.2f %s\n", $result->{surfaceRecurringCost}, $currency);
        }
        $text .= sprintf("Total costs: %.2f %s\n", $result->{totalCost}, $currency);
        $text .= sprintf("Scheduled advances: %.2f %s (%d)\n",
            $result->{advanceAmount}, $currency, $result->{advanceCount});
        $text .= sprintf("Financial reserve: %.2f %s\n", $result->{financialReserve}, $currency);
        for my $segment (@{$result->{segments} // []}) {
            $text .= sprintf("  %s - %s: %.4f, %.2f %s (tariff %s)\n",
                $segment->{startDate}, $segment->{endDate},
                $segment->{counterConsumption}, $segment->{totalCost},
                $currency, $segment->{tariffId} // '-');
        }
        return $text;
    }

    if ($cmd eq "cost") {
        my $data = cm_coreLoad($hash);
        return "Unable to load storage" unless $data;
        ConsumptionManager_SyncWastewaterBaselines($hash, $data);
        my ($day, $month, $year) = cm_dateKeys();
        my $lastMonthEnd = "$month-01";
        my $lastMonthDay = ConsumptionManager_PreviousDate($lastMonthEnd);
        my $lastMonthStart = defined($lastMonthDay)
            ? substr($lastMonthDay, 0, 7) . '-01' : undef;
        my @periods = (
            [ 'Today', $day, undef ],
            [ 'Yesterday', ConsumptionManager_PreviousDate($day), $day ],
            [ 'Month', "$month-01", undef ],
            [ 'Last month', $lastMonthStart, $lastMonthEnd ],
            [ 'Year', "$year-01-01", undef ],
            [ 'Last year', ($year - 1) . '-01-01', "$year-01-01" ],
        );
        my $billingMonth = AttrVal($hash->{NAME}, 'billingYearStart', '01');
        $billingMonth = '01' unless $billingMonth =~ /^(?:0[1-9]|1[0-2])$/;
        my $billingStartYear = $year - (substr($month, 5, 2) < $billingMonth ? 1 : 0);
        my $billingStart = sprintf('%04d-%s-01', $billingStartYear, $billingMonth);
        my $previousBillingStart = sprintf('%04d-%s-01', $billingStartYear - 1, $billingMonth);
        push @periods, [ 'Billing year', $billingStart, undef ],
            [ 'Last billing year', $previousBillingStart, $billingStart ];
        my $currency = $data->{settings}{currency} // 'EUR';
        my $text = "Physical costs\n==============================\n";
        for my $period (@periods) {
            my ($label, $start, $end) = @$period;
            my $result = defined($start)
                ? cm_billingCalculatePhysicalPeriod($data, $start, $end)
                : undef;
            if (ref($result) eq 'HASH'
                && ($result->{status} // '') eq 'active'
                && defined $result->{totalCost}) {
                $text .= sprintf("%-20s %.2f %s\n",
                    $label . ':', $result->{totalCost}, $currency);
            }
            else {
                my $reason = ref($result) eq 'HASH'
                    ? ($result->{error} // $result->{status} // 'unknown')
                    : 'missing physical readings or tariff';
                $text .= sprintf("%-20s n/a (%s)\n", $label . ':', $reason);
            }
        }
        return $text;
    }

    return "Unknown argument $cmd, choose one of advance advanceHistory billing overview cost counterHistory meterChanges tariff tariffHistory";
}

###############################################################################
# Synchronize the configured counter source on demand. Derived wastewater
# devices can be created after the water device already has a physical counter;
# in that case no new event may arrive immediately, so seed the local meter
# from the existing source reading before billing.
###############################################################################

sub ConsumptionManager_SyncCounterSource {
    my ($hash) = @_;

    return undef unless defined $hash && ref($hash) eq 'HASH';
    return undef if ($hash->{MEDIUM} // "") eq "wastewater";

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
# Use the linked water ConsumptionManager's physical meter history for wastewater.
sub ConsumptionManager_SyncWastewaterBaselines {
    my ($hash, $data) = @_;
    return 0 unless ref($hash) eq 'HASH' && ref($data) eq 'HASH'
        && ($hash->{MEDIUM} // '') eq 'wastewater';
    my $sourceName = AttrVal($hash->{NAME}, 'counterDevice', '');
    return 0 unless length($sourceName) && ref($defs{$sourceName}) eq 'HASH';
    my $sourceHash = $defs{$sourceName};
    return 0 unless ($sourceHash->{TYPE} // '') eq 'ConsumptionManager'
        && ($sourceHash->{MEDIUM} // '') eq 'water';
    my $sourceData = cm_coreLoad($sourceHash);
    return 0 unless ref($sourceData) eq 'HASH';
    # Wastewater shares the physical source meter and its replacement history.
    # Copy only into this calculation instance: the source remains authoritative,
    # and no duplicate historical readings are persisted in wastewater JSON.
    $data->{meter} = { %{$sourceData->{meter} // {}} };
    $data->{counterHistory} = [
        map { ref($_) eq 'HASH' ? { %$_ } : $_ }
            @{$sourceData->{counterHistory} // []}
    ];
    $data->{meterChanges} = [
        map { ref($_) eq 'HASH' ? { %$_ } : $_ }
            @{$sourceData->{meterChanges} // []}
    ];
    return 0;
}

#####################################

sub ConsumptionManager_Attr(@)
{
    my ($cmd, $name, $attrName, $attrValue) = @_;

    my $hash = $defs{$name};

    return undef unless defined $hash;

    if ($attrName eq 'billingYearStart') {
        if ($cmd eq 'set') {
            return 'billingYearStart must be 01 through 12'
                unless defined($attrValue) && $attrValue =~ /^(?:0[1-9]|1[0-2])$/;
        }
        ConsumptionManager_UpdateReadings($hash, undef, undef, undef,
            $cmd eq 'set' ? $attrValue : '01');
    }

    if ($attrName eq 'powerUnit') {
        return "powerUnit is only available for electricity and gas"
            unless ($hash->{MEDIUM} // '') =~ /^(?:electricity|gas)$/;
        if ($cmd eq 'set') {
            return "powerUnit must be kW or W"
                unless defined($attrValue) && $attrValue =~ /^(?:kW|W)$/;
        }
        ConsumptionManager_UpdateReadings($hash, undef,
            $cmd eq 'set' ? $attrValue : 'kW');
    }

    if ($attrName eq 'consumptionUnit') {
        my $medium = $hash->{MEDIUM} // '';
        if ($cmd eq 'set') {
            my %allowed = (
                electricity => { Wh => 1, kWh => 1 },
                gas         => { m3 => 1, l => 1 },
                water       => { m3 => 1, l => 1 },
                wastewater  => { m3 => 1, l => 1 },
            );
            return "Invalid unit '$attrValue' for medium '$medium'"
                unless exists $allowed{$medium}{$attrValue};
        }
        # AttrFn runs before FHEM stores the new attribute; pass the new
        # display unit explicitly so the readings refresh immediately.
        ConsumptionManager_UpdateReadings($hash,
            $cmd eq 'set' ? $attrValue
                : (($hash->{MEDIUM} // '') eq 'electricity' ? 'kWh' : 'm3'));
    }

    if ($attrName eq 'flowUnit') {
        return 'flowUnit is only available for gas and water'
            unless ($hash->{MEDIUM} // '') =~ /^(?:gas|water)$/;
        if ($cmd eq 'set') {
            return 'flowUnit must be m3/h or l/h'
                unless defined($attrValue) && $attrValue =~ /^(?:m3\/h|l\/h)$/;
        }
        ConsumptionManager_UpdateReadings($hash, undef, undef,
            $cmd eq 'set' ? $attrValue : 'm3/h');
    }

    if ($attrName eq "counterMultiplier" && $cmd eq "set") {
        return "counterMultiplier must be a positive number"
            unless defined $attrValue
            && $attrValue =~ /^\d+(?:\.\d+)?$/
            && $attrValue > 0;
    }

    if ($cmd eq 'set' && $attrName =~ /^(?:dailyHistoryDays|monthlyHistoryMonths|yearlyHistoryYears)$/) {
        my $maximum = $attrName eq 'dailyHistoryDays' ? 3650
                    : $attrName eq 'monthlyHistoryMonths' ? 120 : 100;
        return "$attrName must be an integer between 0 and $maximum"
            unless defined($attrValue) && $attrValue =~ /^\d+$/ && $attrValue <= $maximum;
    }

    if ($attrName eq "consumptionDecimals" && $cmd eq "set") {
        return "consumptionDecimals must be an integer between 0 and 9"
            unless defined $attrValue
            && $attrValue =~ /^\d+$/
            && $attrValue >= 0
            && $attrValue <= 9;
    }

    if ($attrName eq "currentTimeout" && $cmd eq "set") {
        return "currentTimeout must be a non-negative integer"
            unless defined $attrValue
            && $attrValue =~ /^\d+$/;
    }

    if ($attrName eq "counterDevice") {
        $hash->{NOTIFYDEV} = 'global,' . ($cmd eq "set" ? $attrValue : '');
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
    # Migrate saved configurations after FHEM has loaded their attributes.
    # Keep the legacy fallback until the configuration is saved.
    if (($dev->{NAME} // '') eq 'global') {
        my $events = deviceEvents($dev, 1) // [];
        if (grep { /^(?:INITIALIZED|REREADCFG)(?:$|:)/ } @{$events}) {
            my $name = $hash->{NAME};
            if (defined $attr{$name}{powerTimeout}) {
                my $oldValue = $attr{$name}{powerTimeout};
                if (!defined $attr{$name}{currentTimeout}) {
                    CommandAttr(undef, "$name currentTimeout $oldValue");
                }
                CommandDeleteAttr(undef, "$name powerTimeout");
            }
        }
        return undef;
    }

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
    return undef unless defined $dev->{NAME};
    return undef unless $dev->{NAME} eq $counterDevice;

    # Wastewater derives its counter and history from the linked water
    # ConsumptionManager. It has no counterReading of its own.
    if (($hash->{MEDIUM} // '') eq 'wastewater') {
        return undef unless ($dev->{TYPE} // '') eq 'ConsumptionManager'
            && ($dev->{MEDIUM} // '') eq 'water';
        ConsumptionManager_UpdateReadings($hash);
        return undef;
    }

    return undef unless $counterReading ne "";
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

    # Wastewater has no independent physical meter. Recalculate its readings
    # from the linked water device without writing a second counter history.
    if (($hash->{MEDIUM} // "") eq "wastewater") {
        ConsumptionManager_UpdateReadings($hash);
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
        "currentTimeout",
        AttrVal($hash->{NAME}, "powerTimeout", CM_DEFAULT_POWER_TIMEOUT)
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
# Local calendar boundaries; mktime handles month and year rollover.
sub ConsumptionManager_PreviousDate {
    my ($date) = @_;
    return undef unless defined($date)
        && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my $epoch = mktime(0, 0, 12, $3 - 1, $2 - 1, $1 - 1900);
    my @t = localtime($epoch);
    return sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);
}

sub ConsumptionManager_PreviousMonthStart {
    my ($date) = @_;
    my $previous = ConsumptionManager_PreviousDate($date);
    return undef unless defined($previous);
    return substr($previous, 0, 7) . '-01';
}

sub ConsumptionManager_DisplayUnit {
    my ($hash, $override) = @_;
    my $medium = $hash->{MEDIUM} // '';
    my $default = $medium eq 'electricity' ? 'kWh' : 'm3';
    my $unit = defined($override) ? $override
        : AttrVal($hash->{NAME}, 'consumptionUnit', $default);
    return $unit if ($medium eq 'electricity' && $unit =~ /^(?:Wh|kWh)$/)
        || (($medium eq 'gas' || $medium eq 'water' || $medium eq 'wastewater')
            && $unit =~ /^(?:m3|l)$/);
    return $default;
}

sub ConsumptionManager_UpdateReadings {
    my ($hash, $unitOverride, $powerUnitOverride, $flowUnitOverride, $billingMonthOverride) = @_;
    my $flowUnit = defined($flowUnitOverride) ? $flowUnitOverride
        : AttrVal($hash->{NAME}, 'flowUnit', 'm3/h');
    my $flowFactor = $flowUnit eq 'l/h' ? 1000 : 1;
    my $powerUnit = defined($powerUnitOverride) ? $powerUnitOverride
        : AttrVal($hash->{NAME}, 'powerUnit', 'kW');
    $powerUnit = 'kW' unless $powerUnit eq 'W';
    my $powerFactor = $powerUnit eq 'W' ? 1000 : 1;
    my $displayUnit = ConsumptionManager_DisplayUnit($hash, $unitOverride);
    my $displayFactor = ($displayUnit eq 'Wh' || $displayUnit eq 'l') ? 1000 : 1;

    my $data = cm_coreLoad($hash);

    return unless $data;

    # Wastewater is a derived view of the linked water meter. Never persist
    # its physical meter or history, and never fall back to a legacy virtual
    # counter when the source is temporarily unavailable.
    if (($hash->{MEDIUM} // '') eq 'wastewater') {
        my $sourceName = AttrVal($hash->{NAME}, 'counterDevice', '');
        my $sourceHash = $defs{$sourceName};
        return unless defined($sourceHash)
            && ($sourceHash->{TYPE} // '') eq 'ConsumptionManager'
            && ($sourceHash->{MEDIUM} // '') eq 'water';
        my $sourceData = cm_coreLoad($sourceHash);
        return unless ref($sourceData) eq 'HASH';
        ConsumptionManager_SyncWastewaterBaselines($hash, $data);
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "version", CM_VERSION);


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

    # Meter.pm stores the physical counter rate per hour. The display unit
    # depends on the medium: kW for electricity, m3/h for water and gas.
    # For gas, convert the physical flow using the effective gas tariff.
    my $medium = $hash->{MEDIUM} // '';
    my $rate = $data->{meter}{powerCurrent};
    if ($medium eq 'water') {
        readingsDelete($hash, 'powerCurrent') if exists $hash->{READINGS}{powerCurrent};
        readingsBulkUpdate($hash, 'flowCurrent', $rate * $flowFactor) if defined $rate;
    }
    elsif ($medium eq 'gas') {
        readingsBulkUpdate($hash, 'flowCurrent', $rate * $flowFactor) if defined $rate;
        my $tariff = cm_tariffCurrent($data);
        my $factor = ref($tariff) eq 'HASH'
            ? ($tariff->{calorificValue} // 1) * ($tariff->{stateNumber} // 1)
            : undef;
        readingsBulkUpdate($hash, 'powerCurrent',
            defined($rate) && defined($factor)
                ? sprintf('%.2f', $rate * $factor * $powerFactor)
                : 'n/a');
    }
    elsif ($medium eq 'electricity') {
        readingsDelete($hash, 'flowCurrent') if exists $hash->{READINGS}{flowCurrent};
        readingsBulkUpdate($hash, 'powerCurrent', $rate * $powerFactor) if defined $rate;
    }
    elsif ($medium eq 'wastewater') {
        readingsDelete($hash, 'powerCurrent') if exists $hash->{READINGS}{powerCurrent};
        readingsDelete($hash, 'flowCurrent') if exists $hash->{READINGS}{flowCurrent};
    }

    my $consumptionDecimals = ConsumptionManager_ConsumptionDecimals($hash, $data);
    my $displayDecimals = $displayFactor == 1000
        ? ($consumptionDecimals >= 3 ? $consumptionDecimals - 3 : 0)
        : $consumptionDecimals;
    my $consumptionFormat = "%.${displayDecimals}f";

    # Six standard readings, all calculated from physical midnight boundaries.
    # A missing boundary is unknown (n/a), never a fabricated zero.
    my ($dayKey, $monthKey, $yearKey) = cm_dateKeys();
    my $yesterday = ConsumptionManager_PreviousDate($dayKey);
    my $lastMonthEnd = "$monthKey-01";
    my $lastMonthStart = ConsumptionManager_PreviousMonthStart($lastMonthEnd);
    my $lastYearStart = sprintf('%04d-01-01', $yearKey - 1);
    my @periods = (
        [ 'Today',     $dayKey,            undef ],
        [ 'Yesterday', $yesterday,         $dayKey ],
        [ 'Month',     "$monthKey-01",     undef ],
        [ 'LastMonth', $lastMonthStart,    $lastMonthEnd ],
        [ 'Year',      "$yearKey-01-01",   undef ],
        [ 'LastYear',  $lastYearStart,     "$yearKey-01-01" ],
    );
    # The billing year begins on the first day of the selected month.
    # Completed periods use an exclusive end boundary, as the calendar periods do.
    my $billingMonth = defined($billingMonthOverride) ? $billingMonthOverride
        : AttrVal($hash->{NAME}, 'billingYearStart', '01');
    $billingMonth = '01' unless $billingMonth =~ /^(?:0[1-9]|1[0-2])$/;
    my $currentMonth = substr($monthKey, 5, 2);
    my $billingStartYear = $yearKey - ($currentMonth < $billingMonth ? 1 : 0);
    my $billingStart = sprintf('%04d-%s-01', $billingStartYear, $billingMonth);
    my $previousBillingStart = sprintf('%04d-%s-01', $billingStartYear - 1, $billingMonth);
    push @periods,
        [ 'BillingYear', $billingStart, undef ],
        [ 'LastBillingYear', $previousBillingStart, $billingStart ];
    my %physicalResults;
    for my $period (@periods) {
        my ($label, $start, $end) = @$period;
        my $physical = defined($start)
            ? defined($end)
                ? cm_counterHistoryCalculateRange($data, $start, $end)
                : cm_counterHistoryCalculateCurrent($data, $start)
            : undef;
        $physicalResults{$label} = $physical;
        readingsBulkUpdate($hash, 'consumption' . $label,
            ref($physical) eq 'HASH'
                ? sprintf($consumptionFormat, $physical->{consumption} * $displayFactor)
                : 'n/a');
    }

    # Costs use exactly the same physical boundaries as consumption.
    # Never fall back to legacy virtual/offset billing when history is missing.
    for my $period (@periods) {
        my ($label, $start, $end) = @$period;
        my $result = defined($start)
            ? cm_billingCalculatePhysicalPeriod($data, $start, $end)
            : undef;
        my $valid = ref($result) eq 'HASH'
            && ($result->{status} // '') eq 'active';
        readingsBulkUpdate($hash, 'cost' . $label,
            $valid ? sprintf('%.2f', $result->{totalCost}) : 'n/a');
        if (($hash->{MEDIUM} // '') eq 'gas') {
            readingsBulkUpdate($hash, 'energy' . $label,
                $valid ? sprintf($consumptionFormat,
                    $result->{billingConsumption}) : 'n/a');
        }
    }

    my $billingResult = cm_billingCalculatePhysicalYear($data);
    if (($hash->{MEDIUM} // '') eq 'wastewater') {
        my $validBilling = ref($billingResult) eq 'HASH'
            && ($billingResult->{status} // '') eq 'active';
        readingsBulkUpdate($hash, 'billingSurfaceUsageCost',
            $validBilling ? sprintf('%.2f', $billingResult->{surfaceUsageCost}) : 'n/a');
        readingsBulkUpdate($hash, 'billingSurfaceRecurringCost',
            $validBilling ? sprintf('%.2f', $billingResult->{surfaceRecurringCost}) : 'n/a');
        readingsBulkUpdate($hash, 'billingSurfaceCost',
            $validBilling ? sprintf('%.2f', $billingResult->{surfaceCost}) : 'n/a');
    }
    readingsBulkUpdate($hash, 'financialReserve',
        ref($billingResult) eq 'HASH'
            && ($billingResult->{status} // '') eq 'active'
            ? sprintf('%.2f', $billingResult->{financialReserve})
            : 'n/a');

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
# Midnight snapshots use a dedicated timer identity. The currentTimeout timer
# continues to use the device hash, so resetting it never cancels this timer.
###############################################################################
sub ConsumptionManager_ScheduleMidnight {
    my ($hash) = @_;
    return unless defined $hash && defined $hash->{NAME};

    $hash->{helper} ||= {};
    # A fresh identity prevents an already queued old callback from acting
    # on the rescheduled timer (notably across restart/redefine races).
    RemoveInternalTimer($hash->{helper}{cmMidnightTimer})
        if ref($hash->{helper}{cmMidnightTimer}) eq 'HASH';
    my $timer = { device => $hash->{NAME} };
    $hash->{helper}{cmMidnightTimer} = $timer;

    my @now = localtime(time());
    my $next = mktime(0, 0, 0, $now[3] + 1, $now[4], $now[5]);
    $timer->{scheduledAt} = $next;
    InternalTimer($next, 'ConsumptionManager_MidnightTimer', $timer, 0);
    return;
}

sub ConsumptionManager_MidnightTimer {
    my ($timer) = @_;
    return unless ref($timer) eq 'HASH';
    my $name = $timer->{device};
    return unless defined $name && exists $defs{$name};
    my $hash = $defs{$name};
    return unless ref($hash->{helper}{cmMidnightTimer}) eq 'HASH'
        && $hash->{helper}{cmMidnightTimer} == $timer;

    my $scheduledAt = $timer->{scheduledAt};
    # Rearm independently from the power timeout, even on storage errors.
    ConsumptionManager_ScheduleMidnight($hash);
    return unless defined($scheduledAt) && $scheduledAt =~ /^\d+$/;
    return if time() < $scheduledAt;

    my @scheduled = localtime($scheduledAt);
    my $boundaryDate = sprintf('%04d-%02d-%02d',
        $scheduled[5] + 1900, $scheduled[4] + 1, $scheduled[3]);
    ConsumptionManager_CaptureMidnight($hash, $boundaryDate, 'lastKnown');
    # Refresh period and tariff-dependent readings after the new day boundary.
    ConsumptionManager_UpdateReadings($hash);
    return;
}

# Persist one boundary per day. At restart only today's missing boundary is
# recovered; never fill several missed days with one present-day reading.
sub ConsumptionManager_CaptureMidnight {
    my ($hash, $date, $quality) = @_;
    return unless ref($hash) eq 'HASH';
    # Only the physical water meter records midnight boundaries.
    return if ($hash->{MEDIUM} // "") eq "wastewater";
    my @now = localtime(time());
    my $today = sprintf('%04d-%02d-%02d',
        $now[5] + 1900, $now[4] + 1, $now[3]);
    $date = $today unless defined $date;
    return unless $date eq $today;

    my $data = cm_coreLoad($hash);
    return unless ref($data) eq 'HASH'
        && ref($data->{meter}) eq 'HASH'
        && defined($data->{meter}{current})
        && $data->{meter}{current} =~ /^\d+(?:\.\d+)?$/;
    $data->{counterHistory} ||= [];
    return unless ref($data->{counterHistory}) eq 'ARRAY';
    return if grep {
        ref($_) eq 'HASH' && ($_->{date} // '') eq $date
    } @{ $data->{counterHistory} };

    my @kinds = ('day');
    push @kinds, 'month' if $now[3] == 1;
    push @kinds, 'year' if $now[3] == 1 && $now[4] == 0;
    push @kinds, 'tariff' if ref($data->{tariffs}) eq 'ARRAY' && grep {
        ref($_) eq 'HASH' && ($_->{validFrom} // '') eq $date
    } @{ $data->{tariffs} };

    my $capturedAt = ConsumptionManager_SnapshotTimestamp();
    my $observedAt = $data->{meter}{lastUpdate} // '';
    # Only a sample observed before midnight may serve as the last-known
    # midnight estimate. Do not move the boundary to a post-midnight reading.
    my $boundaryAt = $date . ' 00:00:00';
    return unless $observedAt =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
        && $observedAt lt $boundaryAt;

    my $source = $quality eq 'estimatedAfterRestart'
        ? 'estimatedAfterRestart' : 'lastKnownReading';
    push @{ $data->{counterHistory} }, {
        date => $date,
        boundary => $date . ' 00:00:00',
        capturedAt => $capturedAt,
        observedAt => $observedAt,
        boundaryExact => 0,
        counter => 0 + $data->{meter}{current},
        kinds => \@kinds,
        source => $source,
    };
    ConsumptionManager_PruneCounterHistory($hash, $data, $date);
    Log3($hash, 3, $hash->{NAME} . ': Unable to save midnight snapshot')
        unless cm_coreSave($hash, $data);
    return;
}

# After a restart the first live meter reading can improve a provisional
# snapshot. Only replace a restart estimate, never a normal midnight value.
# Meter replacements on the same day make a comparison unsafe.
# Retention counts refer to completed periods. Keep the opening boundary
# of the oldest retained period, even if it is older than the period itself.
# Tariff boundaries are protected until tariff/billing retention is implemented.
sub ConsumptionManager_PruneCounterHistory {
    my ($hash, $data, $today) = @_;
    return unless ref($data->{counterHistory}) eq 'ARRAY';
    return unless defined($today) && $today =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($year, $month, $day) = ($1, $2, $3);

    my $days   = AttrVal($hash->{NAME}, 'dailyHistoryDays', 7);
    my $months = AttrVal($hash->{NAME}, 'monthlyHistoryMonths', 24);
    my $years  = AttrVal($hash->{NAME}, 'yearlyHistoryYears', 10);
    return unless $days =~ /^\d+$/ && $months =~ /^\d+$/ && $years =~ /^\d+$/;

    my $dayLimit = '';
    if ($days) {
        my $epoch = mktime(0, 0, 0, $day - $days, $month - 1, $year - 1900);
        my @d = localtime($epoch);
        $dayLimit = sprintf('%04d-%02d-%02d', $d[5]+1900, $d[4]+1, $d[3]);
    }
    my $monthLimit = '';
    if ($months) {
        my $epoch = mktime(0, 0, 0, 1, $month - 1 - $months, $year - 1900);
        my @d = localtime($epoch);
        $monthLimit = sprintf('%04d-%02d-01', $d[5]+1900, $d[4]+1);
    }
    my $yearLimit = $years ? sprintf('%04d-01-01', $year - $years) : '';

    # Retain daily snapshots only within the configured daily window.
    # Older month/year opening boundaries are still needed for completed
    # period calculations; keep those independently of daily retention.
    # Also retain custom billing-year boundaries and snapshots needed
    # for tariff boundaries or meter changes, regardless of source.
    my $billingMonth = AttrVal($hash->{NAME}, 'billingYearStart', '01');
    $billingMonth = '01' unless $billingMonth =~ /^(?:0[1-9]|1[0-2])$/;

    my %protectedDates;
    for my $tariff (@{ $data->{tariffs} // [] }) {
        next unless ref($tariff) eq 'HASH';
        my $date = $tariff->{validFrom} // '';
        $protectedDates{$date} = 1 if $date =~ /^\d{4}-\d{2}-\d{2}$/;
    }
    for my $change (@{ $data->{meterChanges} // [] }) {
        next unless ref($change) eq 'HASH';
        my $date = $change->{date} // '';
        $protectedDates{$date} = 1 if $date =~ /^\d{4}-\d{2}-\d{2}$/;
    }

    my @retained = grep {
        my $entry = $_;
        if (ref($entry) ne 'HASH') {
            1; # Never silently discard unrecognized records.
        }
        else {
            my $date = $entry->{date} // substr($entry->{boundary} // '', 0, 10);
            if ($date !~ /^\d{4}-\d{2}-\d{2}$/) {
                1;
            }
            else {
                my $isMonth = substr($date, 8, 2) eq '01';
                my $isYear = substr($date, 5, 5) eq '01-01';
                my $isBilling = $isMonth && substr($date, 5, 2) eq $billingMonth;
                my $hasProtectedKind = ref($entry->{kinds}) eq 'ARRAY'
                    && grep { $_ eq 'tariff' || $_ eq 'meterChange' } @{ $entry->{kinds} };
                $hasProtectedKind || $protectedDates{$date}
                    || ($days && $date ge $dayLimit)
                    || ($months && $isMonth && $date ge $monthLimit)
                    || ($years && $isYear && $date ge $yearLimit)
                    || ($years && $isBilling && $date ge $yearLimit);
            }
        }
    } @{ $data->{counterHistory} };
    $data->{counterHistory} = \@retained;
}

sub ConsumptionManager_SnapshotTimestamp {
    my @t = localtime(time());
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

###############################################################################
sub ConsumptionManager_PowerTimeout {

    my ($hash) = @_;

    cm_coreResetPower($hash);

    my $medium = $hash->{MEDIUM} // '';
    if ($medium eq 'water') {
        readingsSingleUpdate($hash, 'flowCurrent', 0, 1);
    }
    elsif ($medium eq 'gas') {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'flowCurrent', 0);
        readingsBulkUpdate($hash, 'powerCurrent', 0);
        readingsEndUpdate($hash, 1);
    }
    elsif ($medium eq 'electricity') {
        readingsSingleUpdate($hash, 'powerCurrent', 0, 1);
    }

    return;
}

###############################################################################
# Build the dynamic FHEMWEB set command list
###############################################################################

sub ConsumptionManager_SetList {

    my ($hash, $unknown) = @_;

    my @commands = ('counter');
    push @commands, 'counterBoundary', 'counterDelete', 'meterChange', 'meterChangeEdit',
        'meterChangeApply'
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
            'tariffApply',
            'tariffValidFrom',
            'tariffWorkPrice',
            'tariffBasePrice',
            'tariffBasePriceUnit:month,year',
            'tariffCurrency:EUR',
            'tariffComment',
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
        push @commands, 'tariffCreate:noArg', 'tariffEdit', 'tariffApply';
    }

    if ($advanceEditorActive) {
        push @commands,
            'advanceApply',
            'advanceValidFrom',
            'advanceValidTo',
            'advanceAmount',
            'advanceComment',
            'advanceSave:noArg',
            'advanceCancel:noArg';
    }
    else {
        push @commands, 'advanceCreate:noArg', 'advanceEdit', 'advanceApply';
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


###############################################################################
# FHEMWEB detail editor. The form submits ONE FHEM command, not individual
# changes. Existing tariff entries are never modified before a successful save.
###############################################################################
# FHEMWEB exposes FW_CSRF as a query-string fragment (e.g. &fwcsrf=csrf_...).
# HTML form inputs require only the parameter value.
sub ConsumptionManager_FWCsrfValue {
    my ($raw) = @_;
    return '' unless defined $raw && length $raw;
    return $1 if $raw =~ /(?:^|[&?])fwcsrf=([^&]*)/;
    return $raw;
}

sub ConsumptionManager_FWHtml {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

# Display a minimum of two decimals without discarding additional precision.
# Stored tariff values remain unchanged; only HTML presentation is formatted.
sub ConsumptionManager_FWPrice {
    my ($value) = @_;
    return '' unless defined $value && $value ne '';
    my $s = "$value";
    return ConsumptionManager_FWHtml($s)
        unless $s =~ /^([+-]?\d+)(?:\.(\d+))?$/;
    my ($whole, $fraction) = ($1, defined $2 ? $2 : '');
    $fraction .= '0' while length($fraction) < 2;
    return ConsumptionManager_FWHtml($whole . ',' . $fraction);
}

sub ConsumptionManager_FWForm {
    my ($hash, $tariff, $mode) = @_;
    my $name = $hash->{NAME};
    my $medium = $hash->{MEDIUM} // '';
    my $formId = 'cmTariff_'.$mode;
    my @fields = (
        ['validFrom', 'Gültig ab', 'date'],
        ['workPrice', 'Arbeitspreis', 'number'],
        ['basePrice', 'Grundpreis', 'number'],
        ['basePriceUnit', 'Grundpreis je', 'select'],
        ['currency', 'Währung', 'text'],
    );
    push @fields, ['calorificValue','Brennwert (kWh/m³)','number'],
                  ['stateNumber','Zustandszahl','number']
        if $medium eq 'gas';
    push @fields, ['assessmentFactor','Bemessungsfaktor (0–1)','number'],
                  ['surfaceUsageArea','Nutzungsfläche (m²)','number'],
                  ['surfaceUsagePrice','Nutzungsflächenpreis','number'],
                  ['surfaceRecurringArea','Wiederkehrende Fläche (m²)','number'],
                  ['surfaceRecurringPrice','Wiederkehrender Flächenpreis','number']
        if $medium eq 'wastewater';
    push @fields, ['comment','Kommentar','text'];

    my $html = '<form class="cmTariffForm" method="get" action=""'
        .' onsubmit="return cmTariffSubmit(this)">';
    $html .= '<input type="hidden" name="detail" value="'.ConsumptionManager_FWHtml($name).'">';
    $html .= '<input type="hidden" name="cmd" value="">';
    $html .= '<input type="hidden" class="cmTariffDevice" value="'.ConsumptionManager_FWHtml($name).'">';
    $html .= '<input type="hidden" class="cmTariffMode" value="'.ConsumptionManager_FWHtml($mode).'">';
    $html .= '<input type="hidden" name="fwcsrf" value="'.ConsumptionManager_FWHtml(ConsumptionManager_FWCsrfValue($FW_CSRF)).'">'
        if defined $FW_CSRF && length $FW_CSRF;
    $html .= '<table class="block">';
    for my $field (@fields) {
        my ($key,$label,$type) = @$field;
        my $value = defined $tariff->{$key} ? $tariff->{$key} : '';
        # Number inputs require a decimal point, unlike localized table output.
        if (($key eq 'workPrice' || $key eq 'basePrice')
            && defined $value && $value =~ /^([+-]?\d+)(?:\.(\d+))?$/) {
            my ($whole, $fraction) = ($1, defined $2 ? $2 : '');
            $fraction .= '0' while length($fraction) < 2;
            $value = $whole . '.' . $fraction;
        }
        $html .= '<tr><td>'.ConsumptionManager_FWHtml($label).'</td><td>';
        if ($type eq 'select') {
            $html .= '<select data-cm-field="'.$key.'">';
            for my $option (qw(month year)) {
                $html .= '<option value="'.$option.'"'
                    .($value eq $option ? ' selected="selected"' : '').'>'
                    .($option eq 'month' ? 'Monat' : 'Jahr').'</option>';
            }
            $html .= '</select>';
        } else {
            my $step = $type eq 'number' ? ' step="any" min="0"' : '';
            $html .= '<input data-cm-field="'.$key.'" type="'.$type.'"'.$step
                .' value="'.ConsumptionManager_FWHtml($value).'">';
        }
        $html .= '</td></tr>';
    }
    $html .= '</table><button type="submit">Tarif speichern</button> '
        .'<button type="button" onclick="this.form.parentNode.removeChild(this.form)">Abbrechen</button>'
        .'</form>';
    return $html;
}

# Advance payment editor. The same CSRF handling as the tariff editor is used.
sub ConsumptionManager_FWAdvanceForm {
    my ($hash, $advance, $mode) = @_;
    my $name = $hash->{NAME};
    my $html = '<form class="cmAdvanceForm" method="get" action=""'
        .' onsubmit="return cmAdvanceSubmit(this)">';
    $html .= '<input type="hidden" name="detail" value="'.ConsumptionManager_FWHtml($name).'">';
    $html .= '<input type="hidden" name="cmd" value="">';
    $html .= '<input type="hidden" class="cmAdvanceDevice" value="'.ConsumptionManager_FWHtml($name).'">';
    $html .= '<input type="hidden" class="cmAdvanceMode" value="'.ConsumptionManager_FWHtml($mode).'">';
    $html .= '<input type="hidden" name="fwcsrf" value="'
        .ConsumptionManager_FWHtml(ConsumptionManager_FWCsrfValue($FW_CSRF)).'">'
        if defined $FW_CSRF && length $FW_CSRF;
    $html .= '<table class="block">';
    for my $field (
        ['validFrom', 'Gültig ab', 'date'],
        ['validTo', 'Gültig bis (optional)', 'date'],
        ['amount', 'Monatlicher Abschlag', 'text'],
        ['comment', 'Kommentar', 'text'],
    ) {
        my ($key, $label, $type) = @$field;
        my $value = defined $advance->{$key} ? $advance->{$key} : '';
        if ($key eq 'amount' && $value =~ /^([+-]?\d+)(?:\.(\d+))?$/) {
            my ($whole, $fraction) = ($1, defined $2 ? $2 : '');
            $fraction .= '0' while length($fraction) < 2;
            $value = $whole . ',' . $fraction;
        }
        $html .= '<tr><td>'.ConsumptionManager_FWHtml($label).'</td><td>';
        $html .= '<input data-cm-advance-field="'.$key.'" type="'.$type.'"'
            .($key eq 'amount' ? ' inputmode="decimal"' : '')
            .($key eq 'validFrom' || $key eq 'amount' ? ' required' : '')
            .' value="'.ConsumptionManager_FWHtml($value).'"></td></tr>';
    }
    $html .= '</table><button type="submit">Abschlag speichern</button> '
        .'<button type="button" onclick="cmAdvanceCancel(this.form)">Abbrechen</button>'
        .'</form>';
    return $html;
}

sub ConsumptionManager_FWCounterForm {
    my ($hash, $entry) = @_;
    my $name = ConsumptionManager_FWHtml($hash->{NAME});
    my $date = ref($entry) eq 'HASH' ? ($entry->{date} // '') : '';
    my $counter = ref($entry) eq 'HASH' ? ($entry->{counter} // '') : '';
    my $editing = length($date);
    my $html = '<form method="get" action="" onsubmit="return cmCounterSubmit(this)">';
    $html .= '<input type="hidden" name="detail" value="' . $name . '">'
        . '<input type="hidden" name="cmd" value="">'
        . '<input type="hidden" class="cmCounterDevice" value="' . $name . '">';
    $html .= '<input type="hidden" name="fwcsrf" value="'
        . ConsumptionManager_FWHtml(ConsumptionManager_FWCsrfValue($FW_CSRF)) . '">'
        if defined $FW_CSRF && length $FW_CSRF;
    $html .= '<table class="block">'
        . '<tr><td>Stichtag</td><td><input data-cm-counter-date type="date" required'
        . ($editing ? ' readonly' : '')
        . ' value="' . ConsumptionManager_FWHtml($date) . '"></td></tr>'
        . '<tr><td>Zählerstand</td><td><input data-cm-counter-value type="number"'
        . ' min="0" step="any" required value="'
        . ConsumptionManager_FWHtml($counter) . '"></td></tr></table>'
        . '<button type="submit">Zählerstand speichern</button> '
        . '<button type="button" onclick="this.closest(\'div\').style.display=\'none\'">Abbrechen</button>'
        . '</form>';
    return $html;
}

sub ConsumptionManager_FWDetail {
    my ($FW_wname, $name, $room, $pageHash) = @_;
    my $hash = $defs{$name};
    return '' unless $hash;
    my $data = cm_coreLoad($hash);
    return '' unless $data;

    my $html = '<div class="consumptionManagerTariffs"><h3>Tarifverwaltung</h3>';
    $html .= '<table class="block wide"><tr><th>ID</th><th>Gültig ab</th>'
           . '<th>Gültig bis</th><th>Arbeitspreis</th><th>Grundpreis</th><th>Aktion</th></tr>';
    my @tariffs = sort { ($b->{validFrom} // '') cmp ($a->{validFrom} // '') }
                  grep { ref($_) eq 'HASH' } @{ $data->{tariffs} // [] };
    for my $tariff (@tariffs) {
        my $id = $tariff->{id};
        next unless defined $id && $id =~ /^\d+$/;
        $html .= '<tr>';
        for my $field (qw(id validFrom validTo workPrice basePrice)) {
            my $shown = $field eq 'workPrice' || $field eq 'basePrice'
                ? ConsumptionManager_FWPrice($tariff->{$field})
                : ConsumptionManager_FWHtml($tariff->{$field});
            $html .= '<td>'.$shown.'</td>';
        }
        $html .= '<td><button type="button" onclick="cmTariffToggle('
            ."'cmTariffEdit_".$id."'".')">Bearbeiten</button></td></tr>';
        $html .= '<tr id="cmTariffEdit_'.$id.'" style="display:none"><td colspan="6">'
            .ConsumptionManager_FWForm($hash, $tariff, $id).'</td></tr>';
    }
    $html .= '</table>';

    # Prepare a new tariff from the latest existing tariff without writing storage.
    my $copy = eval { JSON::PP->new->decode(JSON::PP->new->encode($data)) };
    if ($copy && cm_tariffCreate($hash, $copy)) {
        # Prefer the currently valid tariff, not an upcoming scheduled tariff.
        # Keep the editor defaults and the fresh validity date/snapshot.
        my $current = cm_tariffCurrent($data);
        if ($current && ref($current) eq 'HASH') {
            for my $field (qw(workPrice basePrice basePriceUnit currency
                calorificValue stateNumber assessmentFactor surfaceUsageArea
                surfaceUsagePrice surfaceRecurringArea surfaceRecurringPrice comment)) {
                $copy->{tariffEditor}{$field} = $current->{$field}
                    if defined $current->{$field};
            }
        }
        $html .= '<p><button type="button" onclick="cmTariffToggle('
            ."'cmTariffNew'".')">Neuen Tarif anlegen</button></p>';
        $html .= '<div id="cmTariffNew" style="display:none">'
            .ConsumptionManager_FWForm($hash, $copy->{tariffEditor}, 'new').'</div>';
    }
    $html .= <<'CM_TARIFF_SCRIPT';
<script>
function cmTariffToggle(id) {
    var el = document.getElementById(id);
    if (el) el.style.display = el.style.display === 'none' ? '' : 'none';
}
function cmTariffSubmit(form) {
    var fields = form.querySelectorAll('[data-cm-field]');
    var values = {};
    for (var i = 0; i < fields.length; i++) {
        values[fields[i].getAttribute('data-cm-field')] = fields[i].value;
    }
    var device = form.querySelector('.cmTariffDevice').value;
    var mode = form.querySelector('.cmTariffMode').value;
    form.elements.cmd.value = 'set ' + device + ' tariffApply ' + mode + ' ' + JSON.stringify(values);
    return true;
}
</script>
CM_TARIFF_SCRIPT
    $html .= '<div class="consumptionManagerAdvances"><h3>Abschlagsverwaltung</h3>';
    $html .= '<table class="block wide"><tr><th>ID</th><th>Gültig ab</th>'
        .'<th>Gültig bis</th><th>Betrag</th><th>Kommentar</th><th>Aktion</th></tr>';
    my @advances = sort { ($b->{validFrom} // '') cmp ($a->{validFrom} // '') }
        grep { ref($_) eq 'HASH' } @{ $data->{advances} // [] };
    for my $advance (@advances) {
        my $id = $advance->{id};
        next unless defined $id && $id =~ /^\d+$/;
        $html .= '<tr>';
        for my $field (qw(id validFrom validTo amount comment)) {
            my $value = $field eq 'amount'
                ? ConsumptionManager_FWPrice($advance->{$field})
                : ConsumptionManager_FWHtml($advance->{$field});
            $html .= '<td>'.$value.'</td>';
        }
        $html .= '<td><button type="button" onclick="cmTariffToggle('
            ."'cmAdvanceEdit_".$id."'".')">Bearbeiten</button></td></tr>';
        $html .= '<tr id="cmAdvanceEdit_'.$id.'" style="display:none"><td colspan="6">'
            .ConsumptionManager_FWAdvanceForm($hash, $advance, $id).'</td></tr>';
    }
    $html .= '<tr><td colspan="6">Keine Abschläge vorhanden.</td></tr>'
        unless @advances;
    $html .= '</table>';
    my $advanceCopy = eval { JSON::PP->new->decode(JSON::PP->new->encode($data)) };
    if ($advanceCopy && cm_advanceCreate($advanceCopy)) {
        my ($previousAdvance) = sort {
            ($b->{validFrom} // '') cmp ($a->{validFrom} // '')
        } grep { ref($_) eq 'HASH' } @{ $data->{advances} // [] };
        if ($previousAdvance && defined $previousAdvance->{amount}) {
            $advanceCopy->{advanceEditor}{amount} = $previousAdvance->{amount};
        }
        $html .= '<p><button type="button" onclick="cmTariffToggle('
            ."'cmAdvanceNew'".')">Neuen Abschlag anlegen</button></p>';
        $html .= '<div id="cmAdvanceNew" style="display:none">'
            .ConsumptionManager_FWAdvanceForm($hash, $advanceCopy->{advanceEditor}, 'new')
            .'</div>';
    }
    $html .= <<'CM_ADVANCE_SCRIPT';
<script>
function cmAdvanceCancel(form) {
    // Editing forms live in a table row; the new-entry form lives in a div.
    // The form's immediate parent is a table cell, not the collapsible panel.
    var panel = form.closest('tr[id], div[id]');
    if (panel) panel.style.display = 'none';
}
function cmAdvanceSubmit(form) {
    var fields = form.querySelectorAll('[data-cm-advance-field]');
    var values = {};
    for (var i = 0; i < fields.length; i++) {
        values[fields[i].getAttribute('data-cm-advance-field')] = fields[i].value;
    }
    if (values.amount !== undefined) {
        values.amount = values.amount.trim().replace(',', '.');
        if (!/^\d+(?:\.\d+)?$/.test(values.amount)) {
            alert('Bitte einen gültigen Abschlagsbetrag eingeben.');
            return false;
        }
    }
    var device = form.querySelector('.cmAdvanceDevice').value;
    var mode = form.querySelector('.cmAdvanceMode').value;
    form.elements.cmd.value = 'set ' + device + ' advanceApply ' + mode + ' ' + JSON.stringify(values);
    return true;
}
</script>
CM_ADVANCE_SCRIPT
    $html .= '</div>';

    # Physical counter management is intentionally read-only until the
    # migration from legacy baselines and tariff snapshots is complete.
    # Wastewater will use its linked water device's physical history.
    my $historyData = $data;
    my $historySource = '';
    if (($hash->{MEDIUM} // '') eq 'wastewater') {
        my $sourceName = AttrVal($name, 'counterDevice', '');
        if ($sourceName ne '' && defined $defs{$sourceName}
            && ($defs{$sourceName}{TYPE} // '') eq 'ConsumptionManager'
            && ($defs{$sourceName}{MEDIUM} // '') eq 'water') {
            my $sourceData = cm_coreLoad($defs{$sourceName});
            if (ref($sourceData) eq 'HASH') {
                $historyData = $sourceData;
                $historySource = $sourceName;
            }
        }
    }
    $html .= '<div class="consumptionManagerCounters"><h3>Zählerstandsverwaltung</h3>';
    if ($historySource eq '' && ($hash->{MEDIUM} // '') eq 'wastewater') {
        $html .= '<p>Kein verbundenes Wassergerät verfügbar. '
            . 'Die bisher gespeicherten Werte bleiben unverändert.</p>';
    }
    my $canManageHistory = ($hash->{MEDIUM} // '') ne 'wastewater';
    $html .= '<table class="block wide"><tr><th>Stichtag</th><th>Zählerstand</th>'
        . '<th>Abgelesen</th><th>Erfasst</th><th>Quelle</th><th>Aktion</th></tr>';
    my @history = sort {
        ($b->{boundary} // $b->{date} // '') cmp ($a->{boundary} // $a->{date} // '')
    } grep { ref($_) eq 'HASH' } @{
        ref($historyData->{counterHistory}) eq 'ARRAY'
            ? $historyData->{counterHistory} : []
    };
    for my $entry (@history) {
        my $date = $entry->{date} // '';
        my $manual = ($entry->{source} // '') eq 'manual';
        $html .= '<tr>';
        for my $field ('boundary', 'counter', 'observedAt', 'capturedAt', 'source') {
            my $value = $field eq 'boundary'
                ? ($entry->{boundary} // $entry->{date} // '')
                : ($entry->{$field} // '');
            $html .= '<td>' . ConsumptionManager_FWHtml($value) . '</td>';
        }
        if ($canManageHistory && $date =~ /^\d{4}-\d{2}-\d{2}$/) {
            if ($manual) {
                my $editId = 'cmCounterEdit_' . $date;
                $html .= '<td><button type="button" onclick="cmTariffToggle(\''
                    . $editId . '\')">Bearbeiten</button> '
                    . '<button type="button" onclick="cmCounterDelete(\''
                    . ConsumptionManager_FWHtml($name) . '\',\''
                    . ConsumptionManager_FWHtml($date) . '\')">Löschen</button></td></tr>';
                $html .= '<tr id="' . $editId
                    . '" style="display:none"><td colspan="6">'
                    . ConsumptionManager_FWCounterForm($hash, $entry) . '</td></tr>';
            } else {
                $html .= '<td>Automatisch</td></tr>';
            }
        } else {
            $html .= '<td>–</td><td>–</td></tr>';
        }
    }
    $html .= '<tr><td colspan="6">Noch keine Stichtagswerte vorhanden.</td></tr>'
        unless @history;
    $html .= '</table>';
    if ($canManageHistory) {
        $html .= '<p><button type="button" onclick="cmTariffToggle(\'cmCounterNew\')">'
            . 'Neuen Zählerstand anlegen</button></p>';
        $html .= '<div id="cmCounterNew" style="display:none">'
            . ConsumptionManager_FWCounterForm($hash, undef) . '</div>';
    }
    $html .= '<h4>Zählerwechsel</h4>';
    my @changes = sort {
        ($b->{date} // '') cmp ($a->{date} // '')
    } grep { ref($_) eq 'HASH' } @{
        ref($historyData->{meterChanges}) eq 'ARRAY'
            ? $historyData->{meterChanges} : []
    };
    $html .= '<table class="block wide"><tr><th>Datum</th><th>Uhrzeit</th><th>Alter Endstand</th>'
        . '<th>Neuer Anfangsstand</th><th>Kommentar</th><th>Aktion</th></tr>';
    for my $change (@changes) {
        my $originalIndex = -1;
        for my $i (0 .. $#{ $historyData->{meterChanges} }) {
            if ($historyData->{meterChanges}[$i] == $change) {
                $originalIndex = $i;
                last;
            }
        }
        $html .= '<tr>';
        for my $field (qw(date effectiveAt oldCounter newCounter comment)) {
            my $value = $field eq 'effectiveAt'
                ? substr(($change->{effectiveAt} // ''), 11)
                : ($change->{$field} // '');
            $html .= '<td>' . ConsumptionManager_FWHtml($value) . '</td>';
        }
        if (($hash->{MEDIUM} // '') ne 'wastewater' && $originalIndex >= 0) {
            my $editId = 'cmMeterEdit_' . $originalIndex;
            $html .= '<td><button type="button" onclick="cmTariffToggle(\''
                . $editId . '\')">Bearbeiten</button></td></tr>';
            $html .= '<tr id="' . $editId . '" style="display:none"><td colspan="6">';
            $html .= '<form method="get" action="" onsubmit="return cmMeterSubmit(this)">';
            $html .= '<input type="hidden" name="detail" value="'
                . ConsumptionManager_FWHtml($name) . '">';
            $html .= '<input type="hidden" name="cmd" value="">';
            $html .= '<input type="hidden" class="cmMeterDevice" value="'
                . ConsumptionManager_FWHtml($name) . '">';
            $html .= '<input type="hidden" class="cmMeterIndex" value="'
                . $originalIndex . '">';
            $html .= '<input type="hidden" name="fwcsrf" value="'
                . ConsumptionManager_FWHtml(ConsumptionManager_FWCsrfValue($FW_CSRF)) . '">'
                if defined $FW_CSRF && length $FW_CSRF;
            $html .= '<table class="block">';
            for my $field (
                ['date', 'Wechseldatum', 'date'],
                ['effectiveAt', 'Wechselzeit (HH:MM oder HH:MM:SS, optional)', 'text'],
                ['oldCounter', 'Alter Endzählerstand', 'number'],
                ['newCounter', 'Neuer Anfangszählerstand', 'number'],
                ['comment', 'Kommentar (optional)', 'text'],
            ) {
                my ($key, $label, $type) = @$field;
                $html .= '<tr><td>' . ConsumptionManager_FWHtml($label)
                    . '</td><td><input data-cm-meter-field="' . $key
                    . '" type="' . $type . '"'
                    . ($type eq 'number' ? ' step="any" min="0"' : '')
                    . ' value="' . ConsumptionManager_FWHtml($key eq 'effectiveAt'
                        ? substr(($change->{effectiveAt} // ''), 11)
                        : ($change->{$key} // '')) . '"'
                    . ($key ne 'comment' && $key ne 'effectiveAt' ? ' required' : '')
                    . '></td></tr>';
            }
            $html .= '</table><button type="submit">Änderungen speichern</button> '
                . '<button type="button" onclick="cmTariffToggle(\''
                . $editId . '\')">Abbrechen</button></form></td></tr>';
        } else {
            $html .= '<td></td></tr>';
        }
    }
    $html .= '<tr><td colspan="6">Keine Zählerwechsel gespeichert.</td></tr>'
        unless @changes;
    $html .= '</table>';
    if (($hash->{MEDIUM} // '') ne 'wastewater') {
        my $formId = 'cmMeterNew_' . $name;
        $html .= '<p><button type="button" onclick="cmMeterNewToggle(\''
            . ConsumptionManager_FWHtml($formId)
            . '\')">Zählerwechsel eintragen</button></p>';
        $html .= '<div id="' . ConsumptionManager_FWHtml($formId)
            . '" style="display:none">';
        $html .= '<form method="get" action="" onsubmit="return cmMeterSubmit(this)">';
        $html .= '<input type="hidden" name="detail" value="'
            . ConsumptionManager_FWHtml($name) . '">';
        $html .= '<input type="hidden" name="cmd" value="">';
        $html .= '<input type="hidden" class="cmMeterDevice" value="'
            . ConsumptionManager_FWHtml($name) . '">';
        $html .= '<input type="hidden" name="fwcsrf" value="'
            . ConsumptionManager_FWHtml(ConsumptionManager_FWCsrfValue($FW_CSRF)) . '">'
            if defined $FW_CSRF && length $FW_CSRF;
        $html .= '<table class="block">';
        for my $field (
            ['date', 'Wechseldatum', 'date'],
            ['effectiveAt', 'Wechselzeit (HH:MM oder HH:MM:SS)', 'text'],
            ['oldCounter', 'Alter Endzählerstand', 'number'],
            ['newCounter', 'Neuer Anfangszählerstand', 'number'],
            ['comment', 'Kommentar (optional)', 'text'],
        ) {
            my ($key, $label, $type) = @$field;
            $html .= '<tr><td>' . ConsumptionManager_FWHtml($label)
                . '</td><td><input data-cm-meter-field="' . $key
                . '" type="' . $type . '"'
                . ($type eq 'number' ? ' step="any" min="0"' : '')
                . ($key ne 'comment' && $key ne 'effectiveAt' ? ' required' : '')
                . '></td></tr>';
        }
        $html .= '</table><button type="submit">Zählerwechsel speichern</button> '
            . '<button type="button" onclick="this.form.parentNode.removeChild(this.form)">Abbrechen</button>'
            . '</form></div>';
        $html .= <<'CM_METER_SCRIPT';
<script>
function cmMeterNewToggle(id) {
    var panel = document.getElementById(id);
    if (!panel) return;
    if (panel.style.display === 'none') {
        var now = new Date();
        var pad = function(n) { return String(n).padStart(2, '0'); };
        var dateField = panel.querySelector('[data-cm-meter-field="date"]');
        var timeField = panel.querySelector('[data-cm-meter-field="effectiveAt"]');
        if (dateField) dateField.value = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
        if (timeField) timeField.value = pad(now.getHours()) + ':' + pad(now.getMinutes()) + ':' + pad(now.getSeconds());
    }
    cmTariffToggle(id);
}
function cmCounterSubmit(form) {
    var device = form.querySelector('.cmCounterDevice').value;
    var date = form.querySelector('[data-cm-counter-date]').value;
    var value = form.querySelector('[data-cm-counter-value]').value;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !/^\d+(?:\.\d+)?$/.test(value)) {
        alert('Bitte gültigen Stichtag und Zählerstand eingeben.');
        return false;
    }
    form.elements.cmd.value = 'set ' + device + ' counterBoundary ' + date + ' ' + value;
    return true;
}
function cmCounterCommand(device, command) {
    var form = document.createElement('form');
    form.method = 'get';
    form.action = '';
    var fields = { detail: device, cmd: 'set ' + device + ' ' + command };
    var csrf = document.querySelector('.consumptionManagerCounters input[name="fwcsrf"]');
    if (csrf) fields.fwcsrf = csrf.value;
    for (var key in fields) {
        var input = document.createElement('input');
        input.type = 'hidden';
        input.name = key;
        input.value = fields[key];
        form.appendChild(input);
    }
    document.body.appendChild(form);
    form.submit();
}
function cmCounterDelete(device, date) {
    if (confirm('Manuellen Zählerstand vom ' + date + ' wirklich löschen?')) {
        cmCounterCommand(device, 'counterDelete ' + date);
    }
}
function cmMeterSubmit(form) {
    var fields = form.querySelectorAll('[data-cm-meter-field]');
    var values = {};
    for (var i = 0; i < fields.length; i++) {
        values[fields[i].getAttribute('data-cm-meter-field')] = fields[i].value;
    }
    var device = form.querySelector('.cmMeterDevice').value;
    // FHEMWEB's command URL parser can reject raw JSON punctuation in
    // query parameters. Use the existing positional meterChange command.
    // The browser encodes the GET form field values automatically.
    var comment = (values.comment || '').replace(/[\r\n]+/g, ' ').trim();
    var editIndex = form.querySelector('.cmMeterIndex');
    var time = (values.effectiveAt || '').trim();
    if (time && !/^\d{2}:\d{2}(?::\d{2})?$/.test(time)) {
        alert('Uhrzeit bitte als HH:MM oder HH:MM:SS eingeben.');
        return false;
    }
    form.elements.cmd.value = 'set ' + device
        + (editIndex ? ' meterChangeEdit ' + editIndex.value : ' meterChange')
        + ' ' + values.date + ' ' + values.oldCounter + ' ' + values.newCounter
        + (time ? ' ' + time : '') + (comment ? ' ' + comment : '');
    return true;
}
</script>
CM_METER_SCRIPT
    }
    $html .= '</div>';
    $html .= '</div>';
    return $html;
}


=begin html_DE

<a id="ConsumptionManager"></a>
<h3>ConsumptionManager</h3>
<ul>
  <li><a href="#ConsumptionManager_define">Definition</a></li>
  <li><a href="#ConsumptionManager_set">SET-Befehle</a></li>
  <li><a href="#ConsumptionManager_get">GET-Befehle</a></li>
  <li><a href="#ConsumptionManager_attr">Attribute</a></li>
  <li><a href="#ConsumptionManager_readings">Readings</a></li>
  <li><a href="#ConsumptionManager_notes">Hinweise</a></li>
</ul>

<p>Der ConsumptionManager verwaltet Zählerstände, Verbräuche, Tarife,
Abschläge und Kosten für Strom, Gas, Wasser und Abwasser. Strom, Gas und
Wasser verwenden physische Zählerstände; Abwasser leitet den Verbrauch
aus einem verknüpften ConsumptionManager-Wassergerät ab.</p>

<a id="ConsumptionManager_define"></a>
<h4>Definition</h4>
<pre>
define StromVerbrauch ConsumptionManager electricity
define GasVerbrauch ConsumptionManager gas
define WasserVerbrauch ConsumptionManager water
define AbwasserVerbrauch ConsumptionManager wastewater
</pre>
<p>Die möglichen Zählertypen sind <code>electricity</code>, <code>gas</code>,
<code>water</code> und <code>wastewater</code>. Ein physischer Zähler kann
über <code>counterDevice</code> und <code>counterReading</code> angebunden
werden. Beim Abwassergerät verweist <code>counterDevice</code> auf das
ConsumptionManager-Gerät für Wasser.</p>
<pre>
attr StromVerbrauch counterDevice Stromzaehler
attr StromVerbrauch counterReading total_energy
attr StromVerbrauch counterMultiplier 0.001

attr AbwasserVerbrauch counterDevice WasserVerbrauch
</pre>
<p>Der <code>counterMultiplier</code> wandelt den Quellwert vor der internen
Verarbeitung um, beispielsweise Wh in kWh. Er ist unabhängig vom
Anzeigeattribut <code>consumptionUnit</code>.</p>

<a id="ConsumptionManager_set"></a>
<h4>SET-Befehle</h4>
<ul>
  <li><code>set &lt;name&gt; counter &lt;wert&gt;</code>:
  physischen Zählerstand manuell übernehmen (nicht für Abwasser).</li>
  <li><code>set &lt;name&gt; counterBoundary &lt;JJJJ-MM-TT&gt; &lt;wert&gt;</code>:
  physischen Zählerstand für eine Tagesgrenze hinterlegen (nicht für Abwasser).</li>
  <li><code>set &lt;name&gt; meterChange &lt;JJJJ-MM-TT&gt; &lt;alt&gt; &lt;neu&gt; [HH:MM[:SS]] [Kommentar]</code>:
  Zählerwechsel erfassen (nicht für Abwasser).</li>
  <li><code>set &lt;name&gt; meterChangeEdit &lt;index&gt; &lt;JJJJ-MM-TT&gt; &lt;alt&gt; &lt;neu&gt; [HH:MM[:SS]] [Kommentar]</code>:
  erfassten Zählerwechsel korrigieren.</li>
  <li><code>meterChangeApply</code>: technischer Speicherbefehl der
  grafischen Zählerwechselmaske.</li>
  <li><code>tariffCreate</code>, <code>tariffEdit &lt;id&gt;</code>,
  <code>tariffSave</code>, <code>tariffCancel</code>:
  Tarifeditor anlegen, öffnen, speichern oder abbrechen.</li>
  <li><code>tariffValidFrom</code>, <code>tariffWorkPrice</code>,
  <code>tariffBasePrice</code>, <code>tariffBasePriceUnit</code>,
  <code>tariffCurrency</code>, <code>tariffComment</code>:
  Felder des aktiven Tarifeditors bearbeiten.</li>
  <li><code>tariffCalorificValue</code> und <code>tariffStateNumber</code>:
  zusätzliche Tarifangaben für Gas.</li>
  <li><code>tariffAssessmentFactor</code>,
  <code>tariffSurfaceUsageArea</code>, <code>tariffSurfaceUsagePrice</code>,
  <code>tariffSurfaceRecurringArea</code> und
  <code>tariffSurfaceRecurringPrice</code>: zusätzliche Angaben für Abwasser.</li>
  <li><code>tariffApply</code>: technischer Speicherbefehl der
  grafischen Tarifmaske.</li>
  <li><code>advanceCreate</code>, <code>advanceEdit &lt;id&gt;</code>,
  <code>advanceSave</code>, <code>advanceCancel</code>:
  Abschlagseditor anlegen, öffnen, speichern oder abbrechen.</li>
  <li><code>advanceValidFrom</code>, <code>advanceValidTo</code>,
  <code>advanceAmount</code>, <code>advanceComment</code>:
  Felder des aktiven Abschlagseditors bearbeiten.</li>
  <li><code>advanceApply</code>: technischer Speicherbefehl der
  grafischen Abschlagsmaske.</li>
</ul>
<p>Die einzelnen Editorfelder werden im SET-Menü abhängig davon angeboten,
ob ein Tarif- oder Abschlagseditor aktiv ist. Die grafischen Formulare
stehen auf der Detailseite des Geräts zur Verfügung.</p>

<a id="ConsumptionManager_get"></a>
<h4>GET-Befehle</h4>
<ul>
  <li><code>get &lt;name&gt; advance</code>: aktuell gültigen Abschlag anzeigen.</li>
  <li><code>get &lt;name&gt; advanceHistory</code>: Abschlagshistorie anzeigen.</li>
  <li><code>get &lt;name&gt; billing</code>: Abrechnung des laufenden Kalenderjahrs ausgeben.</li>
  <li><code>get &lt;name&gt; cost</code>: Kostenübersicht für Verbrauchszeiträume anzeigen.</li>
  <li><code>get &lt;name&gt; counterHistory</code>: gespeicherte physische Tagesgrenzen anzeigen.</li>
  <li><code>get &lt;name&gt; meterChanges</code>: erfasste Zählerwechsel anzeigen.</li>
  <li><code>get &lt;name&gt; tariff</code>: aktuell gültigen Tarif anzeigen.</li>
  <li><code>get &lt;name&gt; tariffHistory</code>: Tarifhistorie anzeigen.</li>
</ul>

<a id="ConsumptionManager_attr"></a>
<h4>Attribute und Standardwerte</h4>
<p>Die genannten Standardwerte gelten, wenn das jeweilige Attribut nicht gesetzt ist.</p>
<ul>
  <li><code>counterDevice</code>: Quellgerät; kein Standard (muss konfiguriert werden).
  Bei Abwasser das verknüpfte ConsumptionManager-Wassergerät.</li>
  <li><code>counterReading</code>: Reading des physischen Zählerstands;
  kein Standard (bei direkter Zähleranbindung erforderlich).</li>
  <li><code>counterMultiplier</code>: Faktor für eingelesene Zählerstände;
  Standard <code>1</code> (keine Umrechnung), z. B. <code>0.001</code> für Wh nach kWh.</li>
  <li><code>consumptionUnit</code>: Anzeigeeinheit für Verbrauch;
  Standard bei Strom <code>kWh</code>, sonst <code>m3</code>.
  Strom: Wh/kWh; Gas, Wasser, Abwasser: m3/l.</li>
  <li><code>flowUnit</code>: Durchflusseinheit bei Gas und Wasser;
  Standard <code>m3/h</code>, alternativ <code>l/h</code>.</li>
  <li><code>powerUnit</code>: Leistungseinheit bei Strom und Gas;
  Standard <code>kW</code>, alternativ <code>W</code>.</li>
  <li><code>billingYearStart</code>: Beginn des Abrechnungsjahres;
  Standard <code>01</code> (Januar), auswählbar <code>01</code> bis <code>12</code>.
  Der Zeitraum beginnt immer am ersten Tag des gewählten Monats;
  <code>05</code> entspricht beispielsweise Mai bis April.</li>
  <li><code>consumptionDecimals</code>: Nachkommastellen der Verbrauchsreadings
  (0 bis 9). Standard: automatische Ermittlung anhand des Quellreadings,
  des Multiplikators oder gespeicherter Zählerdaten; falls keine Ermittlung
  möglich ist, <code>3</code>. Bei Wh/l wird die Anzeigepräzision angepasst.</li>
  <li><code>currentTimeout</code>: Sekunden bis zum Zurücksetzen des
  Momentanwerts ohne neues Zählerereignis; Standard <code>300</code> Sekunden,
  <code>0</code> deaktiviert den Timeout.</li>
  <li><code>dailyHistoryDays</code>: Aufbewahrung der Tageshistorie;
  Standard <code>7</code> Tage, zulässig 0 bis 3650. Ältere tägliche Stichtage werden beim nächsten gespeicherten Tagesstichtag bereinigt, soweit sie nicht für andere Zeiträume geschützt sind.</li>
  <li><code>monthlyHistoryMonths</code>: Aufbewahrung der Monatshistorie;
  Standard <code>24</code> Monate, zulässig 0 bis 120. Monatsanfänge bleiben unabhängig von der Tagesfrist erhalten.</li>
  <li><code>yearlyHistoryYears</code>: Aufbewahrung der Jahreshistorie;
  Standard <code>10</code> Jahre, zulässig 0 bis 100. Jahres- und konfigurierte Abrechnungsjahresanfänge bleiben geschützt.</li>
  <li>Die Bereinigung bewahrt zusätzlich manuell erfasste Stichtage, vorhandene Tarifwechselgrenzen und Zählerwechselgrenzen. <code>0</code> bei einem History-Attribut deaktiviert die Aufbewahrung dieser Periodenart, nicht die anderen Schutzregeln.</li>
  <li><code>disable</code>: Modul deaktivieren; Standard <code>0</code>
  (aktiv), <code>1</code> deaktiviert.</li>
</ul>
<pre>
attr StromVerbrauch consumptionUnit Wh
attr WasserVerbrauch consumptionUnit l
attr GasVerbrauch consumptionUnit m3
attr GasVerbrauch powerUnit W
attr WasserVerbrauch flowUnit l/h
</pre>

<a id="ConsumptionManager_readings"></a>
<h4>Readings</h4>
<ul>
  <li><code>counter</code>: intern verarbeiteter physischer Zählerstand;
  die Anzeigeeinheit <code>consumptionUnit</code> ändert diesen Wert nicht.</li>
  <li><code>consumptionToday</code>, <code>consumptionYesterday</code>,
  <code>consumptionMonth</code>, <code>consumptionLastMonth</code>,
  <code>consumptionYear</code>, <code>consumptionLastYear</code>:
  Verbrauch der jeweiligen Zeiträume in der eingestellten Anzeigeeinheit.</li>
  <li><code>powerCurrent</code>: elektrische Momentanleistung bei Strom
  (kW/W); bei Gas zusätzlich berechnete thermische Leistung (kW/W).</li>
  <li><code>flowCurrent</code>: Momentandurchfluss bei Gas und Wasser
  (m3/h oder l/h).</li>
  <li><code>costToday</code>, <code>costYesterday</code>,
  <code>costMonth</code>, <code>costLastMonth</code>,
  <code>costYear</code>, <code>costLastYear</code>:
  berechnete Kosten der jeweiligen Zeiträume.</li>
  <li><code>energyToday</code>, <code>energyYesterday</code>,
  <code>energyMonth</code>, <code>energyLastMonth</code>,
  <code>energyYear</code>, <code>energyLastYear</code>:
  bei Gas berechnete Energiemengen in kWh.</li>
  <li><code>billingSurfaceUsageCost</code>, <code>billingSurfaceRecurringCost</code>
  und <code>billingSurfaceCost</code>: bei Abwasser die anteiligen
  Flächennutzungsgebühren, wiederkehrenden Flächenbeiträge und deren Summe
  für den tatsächlich abrechenbaren Jahreszeitraum. Die Werte stammen
  aus derselben Jahresabrechnung wie <code>costYear</code>.</li>
  <li><code>financialReserve</code>: berechnete Finanzreserve anhand
  der Verbrauchskosten und hinterlegten Abschläge.</li>
  <li><code>lastUpdate</code>, <code>medium</code>, <code>version</code>
  und <code>state</code>: Aktualisierungs- und Statusinformationen.</li>
</ul>
<p>Readingwerte bleiben ohne angehängte Einheitenzeichen numerisch.
Falls für einen Zeitraum noch keine ausreichenden Zähler- oder Tarifdaten
vorliegen, kann statt eines Zahlenwerts <code>n/a</code> erscheinen.</p>

<p>Die Kosten umfassen den tarifabhängigen Arbeitspreis sowie anteilige
Grundpreise. Bei Gas wird der Zählerverbrauch mit Brennwert und
Zustandszahl in kWh umgerechnet. Bei Abwasser werden zusätzlich der
Bemessungsfaktor und gegebenenfalls Flächengebühren berücksichtigt.
<code>financialReserve</code> stellt die vorgesehenen Abschläge den
berechneten Kosten gegenüber; es ist kein Nachweis tatsächlich
geleisteter Zahlungen.</p>

<a id="ConsumptionManager_notes"></a>
<h4>Hinweise</h4>
<ul>
  <li>Historische Tagesgrenzen dienen als feste Bezugspunkte für die
  Zeitraumberechnung. Fehlen benötigte Grenzen oder Tarifdaten, können
  insbesondere Vorperioden wie <code>LastMonth</code> oder
  <code>LastYear</code> als <code>n/a</code> erscheinen.</li>
  <li>Ein Zählerwechsel verbindet die Verbrauchshistorie des alten und
  neuen Zählers. Datum und gegebenenfalls Uhrzeit des Wechsels müssen
  korrekt hinterlegt sein, damit Zeiträume über den Wechsel hinweg
  berechnet werden können.</li>
  <li>Bei ausbleibenden aktuellen Quellwerten können die heutigen
  Verbrauchs- und Kostenreadings <code>n/a</code> anzeigen, obwohl
  historische Monats- und Jahreswerte weiterhin berechenbar sind.</li>
  <li><code>get &lt;name&gt; billing</code> zeigt die Abrechnung an,
  aktualisiert aber nicht selbst die gespeicherten Readings.</li>
  <li>Die Anzeigeeinheiten ändern keine internen Zählerstände, Tarifdaten
  oder Kostenberechnungen. Bei einem Einheitenwechsel können bestehende
  Log- oder InfluxDB-Zeitreihen Werte in verschiedenen Größenordnungen enthalten.</li>
  <li>Gas: <code>flowCurrent</code> zeigt den Volumenstrom,
  <code>powerCurrent</code> die mit Brennwert und Zustandszahl
  berechnete thermische Leistung.</li>
  <li>Abwasser: Verbrauchswerte werden aus dem verknüpften Wassergerät
  abgeleitet. Es gibt keinen eigenen physischen Zählerwechsel und
  weder <code>flowCurrent</code> noch <code>powerCurrent</code>.</li>
  <li>Tarife und Abschläge besitzen Gültigkeitszeiträume. Zeiträume
  ohne hinterlegten Abschlag werden nicht automatisch mit einem neuen
  Abschlagsbetrag gefüllt.</li>
  <li>Die Jahresabrechnung des Versorgers und tatsächlich erfolgte
  Zahlungen sind nicht mit einer automatisch berechneten Kosten- und
  Abschlagsübersicht gleichzusetzen.</li>
</ul>

=end html_DE

=cut

1;

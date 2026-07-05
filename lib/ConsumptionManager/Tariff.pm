package ConsumptionManager::Tariff;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Utils qw(
    cm_today
    cm_dateCompare
    cm_dateSubtractDay
);

our @EXPORT_OK = qw(
    cm_tariffAdd
    cm_tariffCurrent
    cm_tariffFind
    cm_tariffValidate
    cm_tariffConvert
    cm_tariffCreate
    cm_tariffSetValue
    cm_tariffSave
    cm_tariffCancel
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Tariff

=head1 DESCRIPTION

Tariff management.

=cut

###############################################################################
# Add tariff
###############################################################################

sub cm_tariffAdd {

    my ($data, $tariff) = @_;

    return 0 unless defined $data;
    return 0 unless ref($data) eq 'HASH';

    return 0 unless cm_tariffValidate($tariff);

    $data->{tariffs} ||= [];

    #
    # ID vergeben
    #

    my $nextId = 1;

    foreach my $entry (@{$data->{tariffs}}) {

        next unless defined $entry->{id};

        $nextId = $entry->{id} + 1
            if $entry->{id} >= $nextId;
    }

    $tariff->{id} = $nextId;

    #
    # Alten offenen Tarif schließen
    #

    foreach my $entry (@{$data->{tariffs}}) {

        next unless !defined($entry->{validTo}) || $entry->{validTo} eq '';

        $entry->{validTo} = $tariff->{validFrom};
    }

    #
    # Neuen Tarif übernehmen
    #

    push @{$data->{tariffs}}, $tariff;

    #
    # Nach Gültigkeit sortieren
    #

    @{$data->{tariffs}} =
        sort {
            $a->{validFrom} cmp $b->{validFrom}
        } @{$data->{tariffs}};

    return 1;
}

###############################################################################
# Return current tariff
###############################################################################

sub cm_tariffCurrent {

    my ($data) = @_;

    return cm_tariffFind(
        $data,
        cm_today()
    );
}

###############################################################################
# Find tariff for a given date
###############################################################################

sub cm_tariffFind {

    my ($data, $date) = @_;

    return undef unless defined $data;
    return undef unless ref($data) eq 'HASH';
    return undef unless ref($data->{tariffs}) eq 'ARRAY';

    $date = cm_today()
        unless defined $date && $date ne '';

    foreach my $tariff (
        sort {
            $b->{validFrom} cmp $a->{validFrom}
        } @{$data->{tariffs}}
    ) {

        next
            if defined($tariff->{validFrom})
            && $tariff->{validFrom} gt $date;

        if (
               !defined($tariff->{validTo})
            || $tariff->{validTo} eq ''
            || $tariff->{validTo} ge $date
        ) {
            return $tariff;
        }
    }

    return undef;
}

###############################################################################
# Validate tariff
###############################################################################

sub cm_tariffValidate {

    my ($tariff) = @_;

    return 0 unless defined $tariff;
    return 0 unless ref($tariff) eq 'HASH';

    #
    # Pflichtfelder
    #

    foreach my $field (
        qw(
            validFrom
            workPrice
            basePrice
            basePriceUnit
            currency
            unitCounter
            unitBilling
            calorificValue
            stateNumber
        )
    ) {
        return 0 unless exists $tariff->{$field};
    }

    #
    # Datum
    #

    return 0
        unless $tariff->{validFrom}
            =~ /^\d{4}-\d{2}-\d{2}$/;

    if (
        defined $tariff->{validTo}
        && $tariff->{validTo} ne ''
    ) {

        return 0
            unless $tariff->{validTo}
                =~ /^\d{4}-\d{2}-\d{2}$/;
    }

    #
    # Preise
    #

    return 0
        unless $tariff->{workPrice}
            =~ /^\d+(?:\.\d+)?$/;

    return 0
        unless $tariff->{basePrice}
            =~ /^\d+(?:\.\d+)?$/;

    #
    # Grundpreis-Einheit
    #

    return 0
        unless $tariff->{basePriceUnit}
            =~ /^(day|month|year)$/;

    #
    # Währung
    #

    return 0
        unless $tariff->{currency}
            =~ /^[A-Z]{3}$/;

    #
    # Einheiten
    #

    return 0
        unless $tariff->{unitCounter}
            =~ /^(kWh|Wh|m3|L)$/;

    return 0
        unless $tariff->{unitBilling}
            =~ /^(kWh|Wh|m3|L)$/;

    #
    # Gasparameter
    #

    return 0
        unless $tariff->{calorificValue}
            =~ /^\d+(?:\.\d+)?$/;

    return 0
        unless $tariff->{stateNumber}
            =~ /^\d+(?:\.\d+)?$/;

    return 0
        if $tariff->{calorificValue} <= 0;

    return 0
        if $tariff->{stateNumber} <= 0;

    return 1;
}

###############################################################################
# Convert consumption to billing unit
###############################################################################

sub cm_tariffConvert {

    my ($consumption, $tariff) = @_;

    return 0 unless defined $consumption;
    return 0 unless defined $tariff;
    return 0 unless ref($tariff) eq 'HASH';

    my $factor =
        ($tariff->{calorificValue} // 1)
      * ($tariff->{stateNumber}    // 1);

    return $consumption * $factor;
}

###############################################################################
# Create tariff editor
###############################################################################

sub cm_tariffCreate {

    my ($hash, $data) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;

    my $unitCounter = "kWh";
    my $unitBilling = "kWh";

    if ($hash->{MEDIUM} eq "gas") {

        $unitCounter = "m3";
        $unitBilling = "kWh";

    }
    elsif ($hash->{MEDIUM} eq "water") {

        $unitCounter = "m3";
        $unitBilling = "m3";

    }

    $data->{tariffEditor} = {

        validFrom => cm_today(),
        validTo   => '',

        workPrice => 0,

        basePrice => 0,

        basePriceUnit => 'month',

        currency => 'EUR',

        unitCounter => $unitCounter,
        unitBilling => $unitBilling,

        calorificValue => 1,
        stateNumber    => 1,

        comment => '',
    };

    return 1;
}

###############################################################################
# Set value in tariff editor
###############################################################################

sub cm_tariffSetValue {

    my ($data, $field, $value) = @_;

    return 0 unless defined $data;
    return 0 unless ref($data) eq 'HASH';
    return 0 unless exists $data->{tariffEditor};

    my $editor = $data->{tariffEditor};

    #
    # erlaubte Felder
    #

    my %allowed = map { $_ => 1 } qw(
        validFrom
        validTo
        workPrice
        basePrice
        basePriceUnit
        currency
        unitCounter
        unitBilling
        calorificValue
        stateNumber
        comment
    );

    return 0 unless exists $allowed{$field};

    #
    # Validierung
    #

    if ($field =~ /^(workPrice|basePrice|calorificValue|stateNumber)$/) {

        return 0
            unless defined $value
            && $value =~ /^\d+(?:\.\d+)?$/;

        $value += 0;
    }

    elsif ($field eq "validFrom" || $field eq "validTo") {

        return 0
            unless defined $value
            && $value =~ /^\d{4}-\d{2}-\d{2}$/;
    }

    elsif ($field eq "basePriceUnit") {

        return 0
            unless $value =~ /^(day|month|year)$/;
    }

    elsif ($field eq "currency") {

        return 0
            unless $value =~ /^[A-Z]{3}$/;
    }

    elsif ($field eq "unitCounter"
        || $field eq "unitBilling") {

        return 0
            unless $value =~ /^(kWh|Wh|m3|L)$/;
    }

    #
    # übernehmen
    #

    $editor->{$field} = $value;

    return 1;
}

###############################################################################
# Save tariff editor
###############################################################################

sub cm_tariffSave {

    my ($data) = @_;

    return 0 unless defined $data;
    return 0 unless ref($data) eq 'HASH';

    my $editor = $data->{tariffEditor};

    return 0 unless defined $editor;
    return 0 unless ref($editor) eq 'HASH';

    #
    # Vollständigen Tarif prüfen
    #

    return 0 unless cm_tariffValidate($editor);

    #
    # Aktuellen Tarif ermitteln
    #

    my $current = cm_tariffCurrent($data);

    if (defined $current) {

        #
        # Neuer Tarif muss nach dem bisherigen beginnen
        #

        if (
               defined $current->{validFrom}
            && cm_dateCompare(
                $editor->{validFrom},
                $current->{validFrom}
            ) <= 0
        ) {
            return 0;
        }

        #
        # Alten Tarif schließen
        #

        $current->{validTo} =
            cm_dateSubtractDay(
                $editor->{validFrom}
            );
    }

    #
    # Neuen Tarif übernehmen
    #

    push @{$data->{tariffs}}, { %{$editor} };

    #
    # Editor löschen
    #

    $data->{tariffEditor} = {};

    return 1;
}

###############################################################################
# Cancel tariff editor
###############################################################################

sub cm_tariffCancel {

    my ($data) = @_;

    return 0 unless defined $data;
    return 0 unless ref($data) eq 'HASH';

    $data->{tariffEditor} = {};

    return 1;
}

1;

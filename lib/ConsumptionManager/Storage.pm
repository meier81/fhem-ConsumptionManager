package ConsumptionManager::Storage;

use strict;
use warnings;
use JSON::PP;
use File::Copy;
use File::Path qw(make_path);
use File::Spec;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
    CM_SCHEMA_VERSION
    CM_DEFAULT_DECIMALS
    CM_DEFAULT_CURRENCY
);

use ConsumptionManager::Utils qw(
    cm_timestamp
    cm_dateKeys
);

our @EXPORT_OK = qw(
    cm_storageCreate
    cm_storageLoad
    cm_storageSave
);

our $VERSION = CM_VERSION;

=pod

=head1 NAME

ConsumptionManager::Storage - JSON persistence and schema migration.

=head1 DESCRIPTION

Creates, loads, validates, migrates and saves one JSON file per device.

=cut

sub cm_storageFilename {
    my ($hash) = @_;

    return undef unless defined $hash;

    my $device = $hash->{NAME} || $hash->{name};
    return undef unless defined $device && length $device;
    $device =~ s/[^\w.-]/_/g;

    my $storage_dir = undef;
    if (ref $hash eq 'HASH') {
        $storage_dir = $hash->{attr}{storageDir} if ref $hash->{attr} eq 'HASH';
        $storage_dir ||= $hash->{helper}{storageDir} if ref $hash->{helper} eq 'HASH';
    }

    $storage_dir = './log/ConsumptionManager' unless defined $storage_dir && length $storage_dir;
    $storage_dir =~ s{[\\/]+$}{};

    return File::Spec->catfile($storage_dir, "ConsumptionManager_${device}.json");
}

sub cm_storageCreate {
    my ($hash) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;

    my $dir = File::Spec->catpath((File::Spec->splitpath($filename))[0,1]);
    make_path($dir) unless -d $dir;

    my $data = {
        schema => CM_SCHEMA_VERSION,

        meta => {
            created       => cm_timestamp(),
            modified      => cm_timestamp(),
            moduleVersion => CM_VERSION,
        },

        device => {
            name    => $hash->{NAME},
            medium  => '',
            created => cm_timestamp(),
        },

        meter => {
            current         => undef,
            counterDecimals => undef,
            lastTimestamp   => 0,
            powerCurrent  => 0,
            lastUpdate    => '',
        },

        meterChanges => [],
        counterHistory => [],

        consumption => {},

        tariffs => [],

        advances => [],


        tariffEditor => {},

        advanceEditor => {},


        settings => {
            decimals => CM_DEFAULT_DECIMALS,
            currency => CM_DEFAULT_CURRENCY,
        },
    };

    return cm_storageSave($hash, $data);
}

sub cm_storageLoad {
    my ($hash) = @_;

    my $filename = cm_storageFilename($hash);
    return undef unless defined $filename;
    return undef unless -f $filename;

    open my $fh, '<:encoding(UTF-8)', $filename
        or do {
            warn "Unable to open storage file '$filename' for reading: $!";
            return undef;
        };

    local $/;
    my $json_text = <$fh>;
    close $fh;

    my $json = JSON::PP->new->relaxed;
    my $data = eval { $json->decode($json_text) };
    if ($@) {
        warn "Unable to decode JSON from '$filename': $@";
        return undef;
    }

    # Schema ggf. migrieren, anschließend Struktur prüfen.
    $data = cm_storageMigrate($hash, $data);

    unless (cm_storageValidate($hash, $data)) {
        warn "Invalid storage structure in '$filename'";
        return undef;
    }

    return $data;
}

sub cm_storageSave {
    my ($hash, $data) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;
    return 0 unless defined $data && ref $data eq 'HASH';
    $data->{meta} ||= {};
    $data->{meta}{modified} = cm_timestamp();

    my $dir = File::Spec->catpath((File::Spec->splitpath($filename))[0,1]);
    make_path($dir) unless -d $dir;

    _cm_storageBackup($hash) if -f $filename;

    my $json = JSON::PP->new->pretty->canonical;
    my $json_text = eval { $json->encode($data) };
    if ($@) {
        warn "Unable to encode data to JSON: $@";
        return 0;
    }

    open my $fh, '>:encoding(UTF-8)', $filename
        or do {
            warn "Unable to open storage file '$filename' for writing: $!";
            return 0;
        };

    print $fh $json_text;
    close $fh;

    return 1;
}

sub _cm_storageBackup {
    my ($hash) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;
    return 0 unless -f $filename;

    my $backup_file = "$filename.bak";
    if (copy($filename, $backup_file)) {
        return 1;
    }

    warn "Unable to create backup file '$backup_file': $!";
    return 0;
}

sub cm_storageValidate {
    my ($hash, $data) = @_;

    return 0 unless defined $data && ref $data eq 'HASH';
    return 0 unless exists $data->{schema};
    return 0 unless ref $data->{device}        eq 'HASH';
    return 0 unless ref $data->{meter}         eq 'HASH';
    return 0 unless ref $data->{meterChanges}  eq 'ARRAY';
    return 0 unless ref $data->{counterHistory} eq 'ARRAY';
    return 0 unless ref $data->{consumption}   eq 'HASH';
    return 0 unless ref $data->{tariffs}       eq 'ARRAY';
    return 0 unless ref $data->{advances}      eq 'ARRAY';
    return 0 unless ref $data->{tariffEditor}  eq 'HASH';
    return 0 unless ref $data->{advanceEditor} eq 'HASH';
    return 0 unless ref $data->{settings}      eq 'HASH';
    return 1;
}

sub cm_storageMigrate {
    my ($hash, $data) = @_;

    return undef unless defined $data && ref $data eq 'HASH';

    $data->{meta}         ||= {};
    $data->{device}       ||= {};
    $data->{meter}        ||= {};
    $data->{meterChanges}  = [] unless ref $data->{meterChanges} eq 'ARRAY';
    $data->{counterHistory} = [] unless ref $data->{counterHistory} eq 'ARRAY';
    $data->{consumption}  ||= {};
    $data->{tariffs}       = [] unless ref $data->{tariffs} eq 'ARRAY';
    $data->{advances}      = [] unless ref $data->{advances} eq 'ARRAY';
    $data->{tariffEditor} ||= {};
    $data->{advanceEditor} ||= {};
    $data->{settings}     ||= {};

    # Calendar-year billing is calculated dynamically. Remove legacy manual
    # billing-period configuration during migration.
    delete $data->{billing};
    delete $data->{billingEditor};
    delete $data->{payments};
    delete $data->{statistics};
    delete $data->{forecast};

    if (defined $data->{meter}{counterDecimals}
        && $data->{meter}{counterDecimals} !~ /^\d+$/) {
        $data->{meter}{counterDecimals} = undef;
    }

    # Physical history is authoritative. Old virtual baselines cannot be
    # converted reliably into midnight readings across meter replacements.
    $data->{consumption} = {};

    delete $data->{meter}{previous};
    delete $data->{meter}{firstCounter};
    delete $data->{meter}{firstTimestamp};
    delete $data->{meter}{lastConsumption};
    delete $data->{meter}{yearBaselines};
    delete $data->{meter}{monthBaselines};

    # Ensure stable IDs for data created by older versions. Existing IDs are
    # preserved; missing IDs are assigned deterministically in validity order.
    my %usedTariffIds = map {
        (ref($_) eq 'HASH' && defined($_->{id}) && $_->{id} =~ /^\d+$/)
            ? ($_->{id} => 1) : ()
    } @{$data->{tariffs}};
    my $nextTariffId = 1;
    for my $tariff (sort {
        ($a->{validFrom} // '') cmp ($b->{validFrom} // '')
    } grep { ref($_) eq 'HASH' } @{$data->{tariffs}}) {
        unless (defined($tariff->{id}) && $tariff->{id} =~ /^\d+$/) {
            $nextTariffId++ while $usedTariffIds{$nextTariffId};
            $tariff->{id} = $nextTariffId;
            $usedTariffIds{$nextTariffId} = 1;
        }
    }

    my %usedAdvanceIds = map {
        (ref($_) eq 'HASH' && defined($_->{id}) && $_->{id} =~ /^\d+$/)
            ? ($_->{id} => 1) : ()
    } @{$data->{advances}};
    my $nextAdvanceId = 1;
    for my $advance (sort {
        ($a->{validFrom} // '') cmp ($b->{validFrom} // '')
    } grep { ref($_) eq 'HASH' } @{$data->{advances}}) {
        unless (defined($advance->{id}) && $advance->{id} =~ /^\d+$/) {
            $nextAdvanceId++ while $usedAdvanceIds{$nextAdvanceId};
            $advance->{id} = $nextAdvanceId;
            $usedAdvanceIds{$nextAdvanceId} = 1;
        }
    }

    for my $tariff (@{$data->{tariffs}}) {
        next unless ref($tariff) eq 'HASH';
        $tariff->{counterSnapshot} = undef
            unless exists $tariff->{counterSnapshot};
        $tariff->{counterSnapshotDate} //= '';
        $tariff->{counterSnapshotSource} //= '';
        $tariff->{counterSnapshotExact} =
            $tariff->{counterSnapshotExact} ? 1 : 0;
        $tariff->{assessmentFactor} //= 1;

        # Schema 12: split the former single surface-drainage component into
        # two independent annual EUR/m2 components. Existing surfaceArea/
        # surfacePrice values represent the usage fee and are preserved there.
        $tariff->{surfaceUsageArea} =
            exists $tariff->{surfaceUsageArea}
                ? $tariff->{surfaceUsageArea}
                : ($tariff->{surfaceArea} // 0);
        $tariff->{surfaceUsagePrice} =
            exists $tariff->{surfaceUsagePrice}
                ? $tariff->{surfaceUsagePrice}
                : ($tariff->{surfacePrice} // 0);
        $tariff->{surfaceRecurringArea}  //= 0;
        $tariff->{surfaceRecurringPrice} //= 0;
        delete $tariff->{surfaceArea};
        delete $tariff->{surfacePrice};
    }

    if (ref($data->{tariffEditor}) eq 'HASH' && keys %{$data->{tariffEditor}}) {
        $data->{tariffEditor}{assessmentFactor} //= 1;
        $data->{tariffEditor}{surfaceUsageArea} =
            exists $data->{tariffEditor}{surfaceUsageArea}
                ? $data->{tariffEditor}{surfaceUsageArea}
                : ($data->{tariffEditor}{surfaceArea} // 0);
        $data->{tariffEditor}{surfaceUsagePrice} =
            exists $data->{tariffEditor}{surfaceUsagePrice}
                ? $data->{tariffEditor}{surfaceUsagePrice}
                : ($data->{tariffEditor}{surfacePrice} // 0);
        $data->{tariffEditor}{surfaceRecurringArea}  //= 0;
        $data->{tariffEditor}{surfaceRecurringPrice} //= 0;
        delete $data->{tariffEditor}{surfaceArea};
        delete $data->{tariffEditor}{surfacePrice};
    }

    $data->{settings}{decimals} //= CM_DEFAULT_DECIMALS;
    $data->{settings}{currency} //= CM_DEFAULT_CURRENCY;

    # Retire legacy virtual-counter state only after the old schema has
    # been read and migrated. Never synthesize physical midnight readings
    # from virtual baselines: they are not reliable across replacements.
    delete $data->{meter}{virtual};
    delete $data->{meter}{offset};
    for my $change (@{$data->{meterChanges}}) {
        next unless ref($change) eq 'HASH';
        delete @{$change}{qw(offsetDelta offsetBefore offsetAfter)};
    }
    delete @{$data->{consumption}}{qw(
        dayKey dayBaseline yesterday monthKey monthBaseline lastMonthValue
        yearKey yearBaseline lastYearValue
    )};

    $data->{schema} = CM_SCHEMA_VERSION;
    $data->{meta}{moduleVersion} = CM_VERSION;

    return $data;
}

1;

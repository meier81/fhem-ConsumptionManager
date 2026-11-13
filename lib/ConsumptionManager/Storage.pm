package ConsumptionManager::Storage;

use strict;
use warnings;
use JSON::PP;
use File::Copy;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
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
    cm_storageRename
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


# Move a device's JSON and backup together. Never overwrite another device's data.
# The FHEM RenameFn runs after NAME has been changed.
sub cm_storageRename {
    my ($hash, $old_name) = @_;
    return 'Invalid device reference' unless ref($hash) eq 'HASH';
    return 'Missing old device name' unless defined $old_name && length $old_name;
    my $new_name = $hash->{NAME};
    return 'Missing new device name' unless defined $new_name && length $new_name;
    return undef if $old_name eq $new_name;

    my %old_hash = %{$hash};
    $old_hash{NAME} = $old_name;
    my $old_file = cm_storageFilename(\%old_hash);
    my $new_file = cm_storageFilename($hash);
    return 'Invalid storage filename' unless defined $old_file && defined $new_file;
    return undef if $old_file eq $new_file;
    return "Storage file for '$old_name' does not exist: $old_file" unless -f $old_file;

    my @moves = ([$old_file, $new_file]);
    push @moves, ["$old_file.bak", "$new_file.bak"] if -f "$old_file.bak";
    for my $move (@moves) {
        return "Destination already exists: $move->[1]" if -e $move->[1];
    }

    my @completed;
    for my $move (@moves) {
        unless (rename($move->[0], $move->[1])) {
            my $error = "$!";
            for my $done (reverse @completed) {
                warn "Unable to roll back storage rename: $!" unless rename($done->[1], $done->[0]);
            }
            return "Unable to rename storage '$move->[0]': $error";
        }
        push @completed, $move;
    }

    # Update the embedded device identity while preserving all existing data.
    my $data = cm_storageLoad($hash);
    unless ($data) {
        for my $done (reverse @completed) {
            warn "Unable to roll back storage rename: $!" unless rename($done->[1], $done->[0]);
        }
        return 'Unable to read renamed storage; file move rolled back';
    }
    $data->{device}{name} = $new_name;
    unless (cm_storageSave($hash, $data, { skipBackup => 1 })) {
        for my $done (reverse @completed) {
            warn "Unable to roll back storage rename: $!" unless rename($done->[1], $done->[0]);
        }
        return 'Unable to update renamed device identity; file move rolled back';
    }
    return undef;
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
    my ($hash, $data, $options) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;
    return 0 unless defined $data && ref $data eq 'HASH';
    $options ||= {};

    $data->{meta} ||= {};
    $data->{meta}{modified} = cm_timestamp();

    my $json_text = eval { JSON::PP->new->pretty->canonical->encode($data) };
    if ($@) {
        warn "Unable to encode data to JSON: $@";
        return 0;
    }

    my $dir = File::Spec->catpath((File::Spec->splitpath($filename))[0,1]);
    eval { make_path($dir) unless -d $dir; 1 } or do {
        warn "Unable to create storage directory '$dir': $@";
        return 0;
    };

    # Write a complete replacement in the same directory before touching
    # the existing file. A failed write must never truncate the live JSON.
    my ($fh, $tmp) = eval { tempfile('.cm-write-XXXXXX', DIR => $dir, UNLINK => 0) };
    unless ($fh && defined $tmp) {
        warn "Unable to create temporary storage file in '$dir': $!";
        return 0;
    }
    # Preserve permissions of an existing storage file. New files use 0640
    # (subject to the process umask), rather than tempfile's default 0600.
    my $mode = 0640;
    if (-e $filename) {
        my @stat = stat($filename);
        $mode = $stat[2] & 07777 if @stat;
    }
    unless (chmod($mode, $tmp)) {
        warn "Unable to set permissions on temporary storage file '$tmp': $!";
        close($fh);
        unlink($tmp);
        return 0;
    }
    binmode($fh, ':encoding(UTF-8)');
    my $written = print {$fh} $json_text;
    my $closed = close($fh);
    unless ($written && $closed) {
        warn "Unable to write temporary storage file '$tmp': $!";
        unlink($tmp);
        return 0;
    }

    # Back up the previous complete JSON without ever truncating the
    # existing backup. Rename operations preserve their original .bak.
    if (-f $filename && !$options->{skipBackup}) {
        my ($bak_fh, $bak_tmp) = eval { tempfile('.cm-backup-XXXXXX', DIR => $dir, UNLINK => 0) };
        unless ($bak_fh && defined $bak_tmp) {
            warn "Unable to create temporary backup file in '$dir': $!";
            unlink($tmp);
            return 0;
        }
        close($bak_fh);
        unless (copy($filename, $bak_tmp) && rename($bak_tmp, "$filename.bak")) {
            warn "Unable to update backup '$filename.bak': $!";
            unlink($bak_tmp);
            unlink($tmp);
            return 0;
        }
    }

    unless (rename($tmp, $filename)) {
        warn "Unable to replace storage file '$filename': $!";
        unlink($tmp);
        return 0;
    }
    return 1;
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

package ConsumptionManager::Storage;

use strict;
use warnings;
use JSON;
use File::Copy;
use File::Path qw(make_path);
use File::Spec;
use Exporter 'import';
use ConsumptionManager::Utils qw(cm_timestamp);

our @EXPORT_OK = qw(
    cm_storageCreate
    cm_storageLoad
    cm_storageSave
    cm_storageBackup
    cm_storageRestore
    cm_storageFilename
    cm_storageExists
    cm_storageValidate
    cm_storageMigrate
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

our $VERSION = '1.00';

=pod

=head1 NAME

ConsumptionManager::Storage - JSON-Storage-Funktionen für das ConsumptionManager FHEM-Modul

=head1 SYNOPSIS

    use ConsumptionManager::Storage qw(:all);

    my $filename = cm_storageFilename($hash);
    cm_storageCreate($hash);
    my $data = cm_storageLoad($hash);
    cm_storageSave($hash, $data);

=head1 DESCRIPTION

Dieses Modul kapselt das Lesen, Schreiben und Verwalten von JSON-Speicherdateien.
Alle JSON-Zugriffe erfolgen ausschließlich in dieser Datei. Es werden nur Core-
Module und die explizit genannten Module verwendet.

=head1 FUNCTIONS

=over 4

=item cm_storageFilename($hash)

Ermittelt den vollständigen Dateinamen für den Storage der Device-Daten. Wenn
kein Attribut C<storageDir> vorhanden ist, wird C<./log/> als Verzeichnis
verwendet.

=item cm_storageCreate($hash)

Erzeugt eine neue JSON-Datei mit dem Standard-Datenlayout. Die Datei wird nur
angelegt, wenn ein gültiger Device-Name verfügbar ist.

=item cm_storageLoad($hash)

Liest die JSON-Datei ein und gibt die in Perl-Strukturen dekodierten Daten
zurück. Bei Fehlern wird C<undef> zurückgegeben.

=item cm_storageSave($hash, $data)

Schreibt die übergebenen Daten als formatiertes UTF-8 JSON in die Storage-Datei.
Vorher wird automatisch ein Backup erzeugt.

=item cm_storageBackup($hash)

Kopiert die aktuelle JSON-Datei in eine Backup-Datei mit der Endung C<.bak>.

=item cm_storageRestore($hash)

Stellt eine vorhandene Backup-Datei wieder her.

=item cm_storageExists($hash)

Prüft, ob die Storage-Datei existiert, und gibt C<1> oder C<0> zurück.

=item cm_storageValidate($hash, $data)

Prüft, ob die Daten die Mindeststruktur besitzen. Liefert C<1> bei Erfolg oder
C<0> bei ungültigen Daten.

=item cm_storageMigrate($hash, $data)

Falls ein älteres Schema vorhanden ist, kann hier die Migration stattfinden.
Für Version C<0.1> werden die Daten unverändert zurückgegeben.

=back

=cut

sub cm_storageFilename {
    my ($hash) = @_;

    return undef unless defined $hash;

    my $device = $hash->{NAME} || $hash->{name};
    return undef unless defined $device && length $device;

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
        schema => 1,

        meta => {
            created       => cm_timestamp(),
            modified      => cm_timestamp(),
            moduleVersion => '0.1.0',
        },

        device => {
            name    => $hash->{NAME},
            medium  => '',
            created => cm_timestamp(),
        },

        meter => {
            current    => 0,
            virtual    => 0,
            offset     => 0,
            lastUpdate => '',
        },

        meterChanges => [],

        consumption => {
            daily   => {},
            monthly => {},
            yearly  => {},
        },

        tariffs => [],

        payments => [],

        billing => {
            currentCosts => 0,
            paid         => 0,
            balance      => 0,
        },

        statistics => {},

        forecast => {},

        settings => {
            decimals => 3,
            currency => 'EUR',
        },
    };

    return cm_storageSave($hash, $data);
}

sub cm_storageExists {
    my ($hash) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;
    return -f $filename ? 1 : 0;
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

    my $json = JSON->new->utf8->relaxed;
    my $data = eval { $json->decode($json_text) };
    if ($@) {
        warn "Unable to decode JSON from '$filename': $@";
        return undef;
    }

    return $data;
}

sub cm_storageSave {
    my ($hash, $data) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;
    return 0 unless defined $data && ref $data eq 'HASH';

    my $dir = File::Spec->catpath((File::Spec->splitpath($filename))[0,1]);
    make_path($dir) unless -d $dir;

    cm_storageBackup($hash) if -f $filename;

    my $json = JSON->new->utf8->pretty->canonical;
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

sub cm_storageBackup {
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

sub cm_storageRestore {
    my ($hash) = @_;

    my $filename = cm_storageFilename($hash);
    return 0 unless defined $filename;

    my $backup_file = "$filename.bak";
    return 0 unless -f $backup_file;

    if (copy($backup_file, $filename)) {
        return 1;
    }

    warn "Unable to restore backup file '$backup_file' to '$filename': $!";
    return 0;
}

sub cm_storageValidate {
    my ($hash, $data) = @_;

    return 0 unless defined $data && ref $data eq 'HASH';
    return 0 unless exists $data->{schema};
    return 0 unless exists $data->{device};
    return 0 unless exists $data->{meter};
    return 0 unless exists $data->{consumption};
    return 0 unless exists $data->{settings};
    return 1;
}

sub cm_storageMigrate {
    my ($hash, $data) = @_;

    return $data unless defined $data && ref $data eq 'HASH';
    return $data if defined $data->{schema} && $data->{schema} >= 1;
    return $data;
}

1;

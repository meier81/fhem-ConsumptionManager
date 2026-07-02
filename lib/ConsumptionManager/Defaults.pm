package ConsumptionManager::Defaults;

use strict;
use warnings;
use Exporter 'import';
use constant;

our @EXPORT_OK = qw(
    CM_SCHEMA_VERSION
    CM_VERSION
    CM_DEFAULT_DECIMALS
    CM_DEFAULT_CURRENCY
    CM_MEDIUM_ELECTRICITY
    CM_MEDIUM_GAS
    CM_MEDIUM_WATER
    CM_STORAGE_SUBDIR
    CM_JSON_EXTENSION
    CM_BACKUP_EXTENSION
    CM_DATE_FORMAT
    CM_DATETIME_FORMAT
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

use constant CM_SCHEMA_VERSION      => 1;
use constant CM_VERSION             => '0.1.0';
use constant CM_DEFAULT_DECIMALS    => 3;
use constant CM_DEFAULT_CURRENCY    => 'EUR';
use constant CM_MEDIUM_ELECTRICITY  => 'electricity';
use constant CM_MEDIUM_GAS          => 'gas';
use constant CM_MEDIUM_WATER        => 'water';
use constant CM_STORAGE_SUBDIR      => 'log';
use constant CM_JSON_EXTENSION      => '.json';
use constant CM_BACKUP_EXTENSION    => '.bak';
use constant CM_DATE_FORMAT         => '%Y-%m-%d';
use constant CM_DATETIME_FORMAT     => '%Y-%m-%d %H:%M:%S';

=pod

=head1 NAME

ConsumptionManager::Defaults - Standardkonstanten für das ConsumptionManager-Modul

=head1 SYNOPSIS

    use ConsumptionManager::Defaults qw(:all);

    my $schema = CM_SCHEMA_VERSION;
    my $currency = CM_DEFAULT_CURRENCY;

=head1 DESCRIPTION

Dieses Modul definiert konstante Standardwerte für das ConsumptionManager-Projekt.
Da es C<use constant> verwendet, sind die Werte zur Compile-Zeit verfügbar und
können in anderen Modulen einfach importiert werden.

=head1 CONSTANTS

=over 4

=item CM_SCHEMA_VERSION

Die aktuelle Schema-Version für den Storage. Wert: C<1>.

=item CM_VERSION

Die Version des ConsumptionManager-Moduls. Wert: C<0.1.0>.

=item CM_DEFAULT_DECIMALS

Die Standardanzahl der Dezimalstellen. Wert: C<3>.

=item CM_DEFAULT_CURRENCY

Standardwährung. Wert: C<EUR>.

=item CM_MEDIUM_ELECTRICITY

Bezeichner für das Medium Elektrizität. Wert: C<electricity>.

=item CM_MEDIUM_GAS

Bezeichner für das Medium Gas. Wert: C<gas>.

=item CM_MEDIUM_WATER

Bezeichner für das Medium Wasser. Wert: C<water>.

=item CM_STORAGE_SUBDIR

Standard-Unterverzeichnis für Speicherdaten. Wert: C<log>.

=item CM_JSON_EXTENSION

Dateiendung für JSON-Dateien. Wert: C<.json>.

=item CM_BACKUP_EXTENSION

Dateiendung für Backup-Dateien. Wert: C<.bak>.

=item CM_DATE_FORMAT

Datumsformat-String. Wert: C<%Y-%m-%d>.

=item CM_DATETIME_FORMAT

Datum-Uhrzeit-Format-String. Wert: C<%Y-%m-%d %H:%M:%S>.

=back

=cut

1;

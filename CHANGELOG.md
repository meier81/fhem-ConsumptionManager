## 1.1.0-dev1 - in Entwicklung

- Neues Attribut `billingYearStart` (01 bis 12; Standard 01).
- Verbrauchs- und Kostenreadings für laufendes und vorheriges Abrechnungsjahr.
- Kalenderjahr-Auswertungen bleiben unverändert.
- `get billing` und `get overview` zeigen die Abrechnung seit dem gewählten Abrechnungsbeginn einschließlich Abschlägen und Finanzreserve.
- `get cost` ergänzt das aktuelle und vorherige Abrechnungsjahr.
- Deutsche FHEM-Hilfe um Standardwerte und zulässige Bereiche der Attribute ergänzt.
- Selektive Bereinigung der physischen Zählerstandshistorie aktiviert: tägliche, monatliche und jährliche Fristen mit Schutz von Tarif-, Zählerwechsel-, manuellen und Abrechnungsjahresgrenzen.
- FHEMWEB-Zählerstandsverwaltung: manuellen Stichtag anlegen/bearbeiten/löschen, Checkbox zum dauerhaften Schutz aller Einträge; automatische Werte bleiben nicht editierbar.
- Noch offen: vollständige automatisierte Tests und FHEM-Praxistest.

## 1.0.0 - 2026-11-01

- Erste stabile Veröffentlichung des ConsumptionManager für Strom, Gas, Wasser und Abwasser.
- Verbrauchs- und Kostenberechnung für Tages-, Monats- und Jahreszeiträume.
- Physische Zählerhistorie und Zählerwechsel, inklusive virtueller Zählerfortführung.
- Tarif- und Abschlagsverwaltung in FHEMWEB, einschließlich deutscher Dezimaleingaben.
- Gas-Energieumrechnung und eigenständige Abwasserberechnung mit Flächengebühren.
- Praxistests: Monatswechsel für alle vier Medien und Neustart mit erhaltenen Daten.
- Datenbankschema bleibt Version 15; keine automatische Rückmigration auf ältere Modulstände.
- Keine FHEM-Control-Datei und keine Entwicklungs- oder Testverzeichnisse im Release-Branch.

# Changelog

## 0.5.4

- Gas energy readings are now always created for all six periods.
- `energyYesterday`, `energyLastMonth`, and `energyLastYear` are written as zero when no completed-period consumption exists yet.
- Current-period energy readings likewise report zero when their physical gas consumption is zero.
- Non-zero consumption with missing or inexact tariff data is still not silently converted to zero.

## 0.5.3

- Gas devices now expose `energyToday`, `energyYesterday`, `energyMonth`, `energyLastMonth`, `energyYear` and `energyLastYear` in kWh.
- Existing `consumption...` readings remain in the physical gas-meter unit m3.
- Gas energy values use tariff segments, including historical calorific value and state number changes.

## 0.5.2

- Fixed automatic consumption precision for already existing devices.
- Precision is now resolved from the current source reading first, then stored counter precision, then the stored counter value.
- `consumptionDecimals` remains an explicit override.

## 0.5.0 - 2026-08-14

- Consumption storage simplified to three current virtual-counter baselines: day, month and year.
- Removed stored daily/monthly/yearly consumption time series.
- The six consumption readings remain: today, yesterday, month, last month, year and last year.
- Day/month/year consumption is now derived uniformly as `virtualCounter - baseline`.
- Day, month and year rollovers preserve only the immediately preceding period value.
- Existing schema-13 aggregate data is migrated to the compact baseline model without changing current totals.
- Removed obsolete meter fields `firstCounter`, `firstTimestamp`, `previous` and `lastConsumption`.
- Removed obsolete readings `firstCounter`, `meterOffset`, `consumptionLast` and `advanceCount`.
- Wastewater inherits current day/month/year baselines and previous-period values directly from its water source.
- Storage schema 14.

## 0.4.6 - 2026-08-14

- Fixed consumption totals after meter changes when baselines were configured before the first live counter value.
- Year baseline is now reapplied after every counter update and after meter changes.
- Added optional monthly baselines (`monthBaseline`) for one-time correction when the module is installed after the start of a month.
- Monthly baselines are captured automatically at future month rollovers.
- Wastewater devices inherit monthly baselines from their linked water ConsumptionManager.
- Storage schema 13.

# Changelog

## 0.4.5

- Split wastewater surface drainage into two independent annual EUR/m2 components.
- Added `tariffSurfaceUsageArea` / `tariffSurfaceUsagePrice` for the usage fee.
- Added `tariffSurfaceRecurringArea` / `tariffSurfaceRecurringPrice` for the recurring contribution.
- `get billing` and readings now expose both components separately and as a combined surface total.
- Existing `surfaceArea` / `surfacePrice` values are migrated to the usage-fee component.
- Storage schema updated to version 12.


## 0.4.4

- Added tariffEdit <id> and advanceEdit <id> for correcting stored entries.
- Histories now show stable IDs; legacy entries without IDs receive deterministic IDs during schema-11 migration.
- Fixed wastewater billing initialization when the source water virtualCounter already exists but no Notify event has arrived yet.
- Billing no longer treats an uninitialized virtual zero as a real counter.


## 0.4.2

- Added `wastewater` as a fourth medium.
- Added tariff assessment factor for wastewater (for example 90%).
- Added surface drainage area and annual price per square metre.
- Wastewater can consume the `virtualCounter` of a water ConsumptionManager.
- Added prorated surface-drainage costs to billing and readings.
- Storage schema updated to version 10 with migration defaults for existing tariffs.


## 0.4.1

- Entwicklungsbefehl `get testCost` und seine ausschließlich dafür benötigte Oberfläche entfernt.
- Mehrtarifberechnung für laufenden Tag, Monat und Kalenderjahr zentral in `Billing.pm` abgeschlossen.
- Jahreskosten und `costYear` verwenden jetzt dieselben Tarifsegmente wie `get billing`.
- Exakte manuelle Tarif-Snapshots über `tariffCounterSnapshot` ergänzt.
- Nicht exakte Snapshots werden nicht mehr stillschweigend abgerechnet, sondern eindeutig gemeldet.
- `get <name> tariffHistory` zeigt Tarifzeiträume und Snapshot-Status.
- `get <name> billing` zeigt die verwendeten Tarifsegmente.
- Öffentliche Cost-API um interne, nicht direkt benötigte Rechenhelfer bereinigt.

## 0.4.0

- Vollständiger Refactoring- und Bereinigungsdurchgang ohne neue Fachfunktionen.
- Veralteten verschachtelten `set ... tariff ...`-Einstieg entfernt; die FHEMWEB-Befehle bleiben maßgeblich.
- Nicht verwendete Utility-Funktionen und öffentliche Storage-APIs entfernt.
- Nicht genutzte Storage-Platzhalter `payments`, `statistics` und `forecast` entfernt.
- Storage-Migration entfernt diese Altlasten aus bestehenden JSON-Dateien.
- Grundpreis-Einheit auf die tatsächlich unterstützten Werte `month` und `year` vereinheitlicht.
- Exporte, POD-Dokumentation und interne Backup-Funktion bereinigt.
- Storage-Schema auf Version 9 angehoben.

## 0.3.2

- Manuelle Billing-Zeiträume und der Billing-Editor entfernt.
- `get <name> billing` berechnet automatisch das laufende Kalenderjahr vom 01.01. bis 31.12.
- Jahres-Baselines werden beim ersten Zählerwert eines neuen Kalenderjahres automatisch erfasst.
- Eine manuelle `yearBaseline` bleibt als optionale Import- und Korrekturfunktion erhalten.
- Bestehende alte Billing-Konfiguration wird bei der Storage-Migration entfernt; Tarife und Abschläge bleiben erhalten.
- Storage-Schema auf Version 8 angehoben.

## 0.3.0

- Added configurable billing periods with start/end date and baseline counter.
- Added billing editor and FHEMWEB commands.
- Added multi-tariff billing calculation using tariff counter snapshots.
- Added scheduled advance calculation and financial reserve readings.
- Added explicit advance valid-to support.


## 0.2.6

- Neue gemeinsame Abschlagshistorie für Strom, Gas und Wasser
- Persistenter Abschlagseditor mit `advanceCreate`, `advanceValidFrom`, `advanceAmount`, `advanceComment`, `advanceSave` und `advanceCancel`
- Automatisches Schließen des vorherigen Abschlagszeitraums beim Speichern einer Änderung
- `get <name> advance`, `get <name> advanceEditor` und `get <name> advanceHistory`
- Neues Reading `advanceCurrent`
- Dynamische FHEMWEB-Befehlsliste abhängig vom Abschlagseditor
- Storage-Migration auf Schema 6
- Veralteten irrtümlichen `meterChange`-Block aus `GetFn` entfernt

## 0.2.4

- Tarifabschnitte speichern einen virtuellen Zähler-Snapshot
- Exakte Snapshot-Übernahme aus einer Jahres-Baseline am 1. Januar
- Zukünftige Tarife werden beim ersten Zählerwert ab Gültigkeitsbeginn automatisch initialisiert
- Snapshot-Datum, Quelle und Genauigkeitskennzeichen werden gespeichert
- `get <name> tariff` zeigt den Snapshot-Status
- Storage-Migration auf Schema 5

## 0.2.3

- Datierter, medienunabhängiger Zählerwechsel mit `set <name> meterChange <Datum> <alterStand> <neuerStand> [Kommentar]`
- Persistente Zählerwechselhistorie und kumulativer Offset
- `get <name> meterChanges` zur Kontrolle der Historie
- Neue Readings `meterOffset` und `virtualCounter`
- Jahres-Baseline berücksichtigt Zählerwechsel vor dem Jahresanfang
- Storage-Migration auf Schema 4

## 0.2.2

- Optionale Jahreskorrektur mit `set <name> yearBaseline <Jahr> <Zählerstand>`
- `get <name> yearBaseline [Jahr]` zur Anzeige gespeicherter Jahres-Baselines
- Automatische Neuberechnung des laufenden Jahresverbrauchs bei einer Baseline für das aktuelle Jahr
- Einmalige Speicherung von `firstCounter` und `firstTimestamp` beim ersten Zählerwert
- Storage-Migration auf Schema 3


## 0.2.1

- Automatische Übernahme eines Zähler-Readings per `NotifyFn`
- Neue Attribute `counterDevice`, `counterReading` und `counterMultiplier`
- Gemeinsamer Verarbeitungsweg für manuell gesetzte und automatisch empfangene Zählerstände
- Validierung für `counterMultiplier` und `powerTimeout`
- Optimierung der Notify-Verarbeitung über `NOTIFYDEV`

## 0.2.0

- Tarif-Editor mit `create`, Feldänderungen, `save` und `cancel`
- Tarifvalidierung und überschneidungsfreie Tarifzeiträume
- Umrechnung von Gasverbrauch über Brennwert und Zustandszahl
- Arbeits-, Grund- und Gesamtkostenberechnung
- Kosten-Readings für heute, gestern, Monat, Vormonat, Jahr und Vorjahr
- `get cost` und erweiterter Diagnosebefehl `get testCost`
- Storage-Migration auf Schema 2
- Umstellung auf das Perl-Core-Modul `JSON::PP`
- Bereinigung ungenutzter Imports, Exporte und doppelter Logik
- Vermeidung unnötiger Storage-Schreibvorgänge beim Setzen eines Zählerstands

## 0.1.0

- Projekt gestartet

## 0.2.5

- Added FHEMWEB-friendly flat tariff commands with dropdown support.
- Added dynamic tariff command lists based on editor state and medium.
- Added `get <name> tariffEditor` to inspect the current tariff draft.
- Kept the nested `set <name> tariff ...` syntax for backward compatibility.

# FHEM ConsumptionManager 1.1.0-dev6

ConsumptionManager ist ein FHEM-Modul zur Berechnung und Verwaltung von Strom-, Gas-, Wasser- und Abwasserverbrauch, Kosten, Tarifen, Abschlägen und Zählerwechseln.

## Installation

Die Datei `FHEM/98_ConsumptionManager.pm` nach `FHEM/` und alle Dateien aus `lib/ConsumptionManager/` nach `FHEM/lib/ConsumptionManager/` der FHEM-Installation kopieren. Danach FHEM neu starten. Vor einem Update vorhandene FHEM-Konfiguration und ConsumptionManager-Daten sichern.

Dieses Repository enthält bewusst keine FHEM-Control-Datei. Die Installation erfolgt durch Kopieren der Moduldateien, nicht über `update` mit einer Control-Datei.

## Geräte anlegen

```text
define StromVerbrauch ConsumptionManager electricity
define GasVerbrauch ConsumptionManager gas
define WasserVerbrauch ConsumptionManager water
define AbwasserVerbrauch ConsumptionManager wastewater
```

Die Zähleranbindung erfolgt über die Attribute `counterDevice`, `counterReading` und optional `counterMultiplier`. Bei Abwasser kann als Quelle ein Wasser-ConsumptionManager verwendet werden.

## Bedienung

Die FHEMWEB-Detailseite bietet Tarifverwaltung, Abschlagsverwaltung und Zählerstandshistorie einschließlich Zählerwechsel. Für die Auswertung stehen unter anderem `consumptionToday`, `consumptionYesterday`, `consumptionMonth`, `consumptionLastMonth`, `consumptionYear`, `consumptionLastYear` sowie entsprechende `cost...`-Readings zur Verfügung. Gasgeräte stellen zusätzlich `energy...`-Readings bereit.

Tarife und Abschläge werden datumsbezogen gespeichert. Die Abschlagsverwaltung akzeptiert Eingaben wie `151`, `151,50` und `151.50`.

## Hinweise

Die Version 1.0.0 verwendet das interne Datenschema 15. Vor dem Update ein Backup erstellen; ein Downgrade ist nicht automatisch abgesichert. Der reale Monatswechsel Oktober/November 2026 wurde für alle vier Medien geprüft. Ein vollständiger Praxistest des Jahreswechsels steht noch aus.

Weitere Änderungen siehe [CHANGELOG.md](CHANGELOG.md).

## Version 1.1.0: Abrechnungsjahr und Datenspeicherung

Mit `attr <Device> billingYearStart 05` beginnt das Abrechnungsjahr am 1. Mai und endet am 30. April des Folgejahres. Erlaubt sind die Monatswerte `01` bis `12`; ohne Attribut gilt `01`. Die Kalenderjahr-Readings bleiben erhalten. Ergänzt werden `consumptionBillingYear`, `consumptionLastBillingYear`, `costBillingYear` und `costLastBillingYear`. `get overview` und `get billing` verwenden den gewählten Abrechnungsbeginn; `get cost` zeigt beide Abrechnungsjahre. Geräteumbenennungen übernehmen die JSON-Datei und ihre Sicherung. Die Speicherung erfolgt über eine temporäre Datei; bestehende Dateiberechtigungen bleiben erhalten.

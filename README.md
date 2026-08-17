# FHEM ConsumptionManager

Projektbeschreibung:

Ein FHEM-Modul zur Verwaltung von Strom-, Gas-, Wasser- und Abwasserverbräuchen.

## Automatische Zähleranbindung

```text
attr <ConsumptionManager> counterDevice <FHEM-Device>
attr <ConsumptionManager> counterReading <Reading>
attr <ConsumptionManager> counterMultiplier <Faktor>
```

Beispiel für ein Reading in Wh, das intern als kWh verarbeitet werden soll:

```text
attr Strom counterDevice Stromzaehler
attr Strom counterReading total_energy
attr Strom counterMultiplier 0.001
```


## Optionale Jahreskorrektur

Der laufende Zähler benötigt am Jahreswechsel keine manuelle Anpassung. Eine
Jahres-Baseline dient nur zum Import oder zur Korrektur, beispielsweise wenn das
Modul erst im laufenden Jahr eingerichtet wurde.

```text
set Strom yearBaseline 2026 18342.615
get Strom yearBaseline
```

Für das aktuelle Jahr wird `consumptionYear` unmittelbar aus dem aktuellen
effektiven Zählerstand minus Baseline neu berechnet. Tag und Monat bleiben von
der Korrektur unberührt.


## Kompakte Verbrauchsspeicherung

ConsumptionManager speichert keine Tages-, Monats- oder Jahres-Zeitreihen.
Für die laufenden Perioden werden nur drei fortlaufende virtuelle Zählerstände
als Baselines gehalten:

- Tages-Baseline
- Monats-Baseline
- Jahres-Baseline

Daraus werden `consumptionToday`, `consumptionMonth` und `consumptionYear`
berechnet. Beim Periodenwechsel wird nur der unmittelbar vorherige Wert als
`consumptionYesterday`, `consumptionLastMonth` bzw. `consumptionLastYear`
übernommen. Historische Zeitreihen gehören weiterhin nach InfluxDB/Grafana.

Die Baselines liegen intern auf der `virtualCounter`-Skala und bleiben dadurch
auch über physische Zählerwechsel hinweg konsistent.


## Zählerwechsel

Ein physischer Zählerwechsel wird für Strom, Gas und Wasser identisch erfasst:

```text
set <name> meterChange <YYYY-MM-DD> <alterZählerstand> <neuerZählerstand> [Kommentar]
```

Beispiel:

```text
set Gas meterChange 2026-03-15 9876.542 12.345 Turnuswechsel Netzbetreiber
get Gas meterChanges
```

Der ConsumptionManager bildet daraus einen fortlaufenden virtuellen Zählerstand.


## Tarif-Zähler-Snapshots

Beim Speichern eines Tarifabschnitts wird der fortlaufende virtuelle Zählerstand
als `counterSnapshot` hinterlegt. Beginnt ein Tarif in der Zukunft, bleibt der
Snapshot zunächst `pending` und wird beim ersten Zählerwert ab dem
Gültigkeitsdatum automatisch gesetzt. Für einen Tarif ab dem 1. Januar kann eine
vorhandene `yearBaseline` als exakter Snapshot verwendet werden.

```text
get <name> tariff
```

zeigt neben den Tarifdaten auch Snapshot, Erfassungsdatum und Quelle an.

## FHEMWEB tariff workflow

The tariff editor is exposed through flat commands so FHEMWEB can display the
available actions directly in its set menu:

```text
set <name> tariffCreate
set <name> tariffValidFrom 2026-01-01
set <name> tariffWorkPrice 0.3125
set <name> tariffBasePrice 14.95
set <name> tariffBasePriceUnit month
set <name> tariffSave
```

For gas devices, `tariffCalorificValue` and `tariffStateNumber` are shown as
additional commands. Use `get <name> tariffEditor` to review the draft before
saving it.

## Monatliche Abschläge

Abschläge werden als datierte Zeiträume gespeichert. Eine Änderung wirkt damit
erst ab dem angegebenen Datum und verändert ältere Zeiträume nicht rückwirkend.
Die Bedienung erfolgt über flache FHEMWEB-Befehle:

```text
set <name> advanceCreate
set <name> advanceValidFrom 2026-01-01
set <name> advanceAmount 100
set <name> advanceComment Monatlicher Abschlag
get <name> advanceEditor
set <name> advanceSave
```

Bei einer späteren Änderung wird ein neuer Abschnitt angelegt:

```text
set <name> advanceCreate
set <name> advanceValidFrom 2026-07-01
set <name> advanceAmount 120
set <name> advanceSave
```

Der vorherige Abschnitt endet automatisch am Vortag. Kontrolle:

```text
get <name> advance
get <name> advanceHistory
```

Das Reading `advanceCurrent` enthält den aktuell gültigen monatlichen Abschlag.
Die Berechnung bereits fälliger bzw. tatsächlich gezahlter Abschläge und der
Finanzreserve folgt in einem separaten Billing-Schritt.



## Kalenderjahres-Billing

Für die Abrechnung muss kein Zeitraum angelegt werden. Der ConsumptionManager
berechnet automatisch das laufende Kalenderjahr vom 01.01. bis 31.12.:

```text
get <name> billing
```

Die Ausgabe enthält Jahresverbrauch, Arbeitskosten, Grundkosten, bisher
vorgesehene Abschläge und die Finanzreserve.

Beim ersten Zählerwert eines neuen Kalenderjahres wird der vorherige
Zählerstand automatisch als Startreferenz für das neue Jahr gespeichert. Im
normalen Betrieb ist am Jahreswechsel daher keine Eingabe erforderlich.

`yearBaseline` bleibt nur für Erstinstallation im laufenden Jahr, Datenimport
oder Korrekturen erforderlich:

```text
set Strom yearBaseline 2026 18342.615
```

Abschläge können auf einzelne Monate begrenzt werden, zum Beispiel April bis
Dezember:

```text
set Strom advanceCreate
set Strom advanceValidFrom 2026-04-01
set Strom advanceValidTo 2026-12-31
set Strom advanceAmount 100
set Strom advanceSave
```


## Refactoring-Stand 0.4.0

Der Storage enthält nur noch produktiv verwendete Datenbereiche. Kalenderjahres-Billing, Tarife, Abschläge, Zählerwechsel und optionale Jahres-Baselines bleiben erhalten. Grundpreise werden als Monats- oder Jahrespreis geführt.


## Mehrtarifberechnung

Tarifänderungen innerhalb des laufenden Tages, Monats oder Kalenderjahres werden
über virtuelle Zähler-Snapshots getrennt berechnet. Die Historie ist abrufbar:

```text
get <name> tariffHistory
get <name> billing
```

Wird ein Tarif rückwirkend angelegt, muss der virtuelle Zählerstand am
Gültigkeitsbeginn im Tarifeditor gesetzt werden:

```text
set <name> tariffCreate
set <name> tariffValidFrom 2026-07-01
set <name> tariffCounterSnapshot 30123.456
...
set <name> tariffSave
```

Bei zukünftigen Tarifwechseln setzt das Modul den Snapshot beim ersten
Zählerwert am Gültigkeitstag automatisch. Nicht exakte Snapshots werden nicht
für eine vermeintlich genaue Mehrtarifabrechnung verwendet.


## Wastewater

Wastewater can be defined as a separate ConsumptionManager device and use the
water ConsumptionManager's `virtualCounter` as its source. This keeps physical
meter changes in the water device transparent to wastewater billing.

Example:

```text
define Abwasser ConsumptionManager wastewater
attr Abwasser counterDevice Wasser
attr Abwasser counterReading virtualCounter
attr Abwasser counterMultiplier 1
```

The wastewater tariff supports `tariffAssessmentFactor` (for example `90` or
`0.90`) and two independent rainwater/surface-drainage components:

- `tariffSurfaceUsageArea` and `tariffSurfaceUsagePrice` for the annual usage fee
- `tariffSurfaceRecurringArea` and `tariffSurfaceRecurringPrice` for the annual recurring contribution

Areas are entered in m2 and prices in EUR/m2/year. Wastewater work price remains
EUR/m3. Both surface components are prorated independently over the year and are
shown separately in billing. Existing `surfaceArea`/`surfacePrice` data from
older versions is migrated to the usage-fee component. Advances are configured
independently on the wastewater device.

Example based on two separate assessment positions:

```text
set Abwasser tariffSurfaceUsageArea 290
set Abwasser tariffSurfaceUsagePrice 0.25
set Abwasser tariffSurfaceRecurringArea 315
set Abwasser tariffSurfaceRecurringPrice 0.19
```

This corresponds to 72.50 EUR/year usage fee plus 59.85 EUR/year recurring
contribution, for a total rainwater charge of 132.35 EUR/year.


## Correcting stored entries

Use `get <name> tariffHistory` to find an ID, then `set <name> tariffEdit <id>`. Change the incorrect value(s), inspect with `get <name> tariffEditor`, and finish with `set <name> tariffSave`. Advances use the analogous `advanceHistory`, `advanceEdit`, `advanceEditor`, and `advanceSave` commands.

## Monthly baseline correction

If the module is installed after the start of a month, the consumption before the first captured counter value cannot be reconstructed automatically. An optional one-time monthly baseline can be entered:

```text
set Wasser monthBaseline 2026-08 58.0000
get Wasser monthBaseline
```

The value is the physical counter reading at the start of that month. Existing meter changes are automatically converted to the continuous virtual counter scale. Future month baselines are captured automatically at month rollovers. Wastewater devices inherit monthly baselines from their linked water ConsumptionManager.



### Gas energy readings

Gas keeps the six `consumption...` readings in m3. In addition, gas devices expose `energyToday`, `energyYesterday`, `energyMonth`, `energyLastMonth`, `energyYear` and `energyLastYear` in kWh. The conversion uses the tariff-valid calorific value and state number.

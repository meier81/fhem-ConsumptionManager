# ConsumptionManager: FHEM-Updates (Docker)

Die Update-Quelle auf `main` liefert nur freigegebene Moduldateien. Entwicklungsbranches werden nicht automatisch installiert.

## Vor der erstmaligen Einrichtung

1. Das persistente Docker-Volume mit FHEM-Konfiguration, ConsumptionManager-Daten und den bisherigen Moduldateien sichern. Die Ablage kann je nach Docker-Compose-Konfiguration abweichen.
2. Sicherstellen, dass das Verzeichnis `lib/ConsumptionManager/` relativ zum FHEM-Installationsverzeichnis liegt und vom FHEM-Perl-Prozess über `@INC` gefunden wird. Vorhandene abweichende Modulpfade zunächst prüfen.
3. In FHEM zunächst **nur registrieren und prüfen**:

```text
update add https://raw.githubusercontent.com/meier81/fhem-ConsumptionManager/main/controls_ConsumptionManager.txt
update list
update check https://raw.githubusercontent.com/meier81/fhem-ConsumptionManager/main/controls_ConsumptionManager.txt
```

4. Nur wenn die Vorschau ausschließlich die erwarteten ConsumptionManager-Dateien anzeigt, manuell aktualisieren:

```text
update all https://raw.githubusercontent.com/meier81/fhem-ConsumptionManager/main/controls_ConsumptionManager.txt
shutdown restart
```

**Achtung:** Nach dem Registrieren bezieht auch ein allgemeines `update` die zusätzliche Quelle ein. Wer ausschließlich FHEM selbst aktualisieren will, muss die entsprechende Quelle explizit auswählen.

## Pflege der Control-Datei

`controls_ConsumptionManager.txt` enthält `UPD YYYY-MM-DD_HH:MM:SS BYTEGROESSE PFAD` für jede verteilte Datei. Bei jeder stabilen Veröffentlichung müssen Datum und Byte-Größe zu den Dateien auf `main` passen. Ohne diese Pflege werden gleich große Änderungen möglicherweise nicht erkannt oder unnötige Downloads ausgelöst.

Die Control-Datei enthält keine Verbrauchsdaten oder Konfiguration. Sie darf nur die freigegebenen Programmdateien listen.

## Entwicklung

Der Tarifeditor v0.5.5 befindet sich im Branch `dev/v0.5.5-tariff-editor` und wird von dieser Update-Quelle **nicht** verteilt.

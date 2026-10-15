# Spark NTNU – veilederverktøy

Windows-koden ligger i [`windows/`](windows/). Se [utvikling fra en annen enhet](windows/DEVELOPMENT.md) og [installasjon og testing](README-WINDOWS.md).

## Nedlasting

| Plattform | Nedlasting | Krav |
|---|---|---|
| macOS · Apple Silicon (M1 eller nyere) | [Last ned fra siste utgivelse](https://github.com/martinnguyeen/spark-ntnu-veilederverktoy/releases/latest) | macOS 14+ |
| macOS · Intel | Kommer | macOS 14+ |
| Windows 11 | [Last ned EXE](https://github.com/martinnguyeen/spark-ntnu-veilederverktoy/releases/download/windows-v0.2.0/Spark-NTNU-Windows-x64-0.2.0-Setup.exe) | x64 |

Åpne DMG-filen, dra Spark til **Programmer**, og start appen. DMG-en inneholder den lokale Whisper-modellen (omtrent 466 MB). Bruk eduroam eller NTNU VPN, og lim inn IDUN API-nøkkelen når appen ber om den. Lyd transkriberes lokalt; IDUN-analyse krever tilkobling til NTNU.

Fra og med versjonen som inkluderer Sparkle kan du velge **Se etter oppdateringer** i konto-menyen eller Spark-menyen. Du må installere den første Sparkle-versjonen manuelt fra DMG; appen v0.16.0 kan ikke oppdatere seg selv.

**Sikkerhetsvarsel:** Den eksisterende v0.16.0-testversjonen er ikke notarisert. Den første releasen fra den nye macOS-workflowen får Developer ID-signering og notarisering når engangsoppsettet i GitHub er fullført.

# Lage og publisere en macOS-DMG

DMG-en er selvstendig: den inneholder Spark, `whisper-cli`, nødvendig CPU-backend og bibliotekene den trenger, samt NB-Whisper-modellen. Brukeren trenger ikke Homebrew eller Terminal.

## Bygg lokalt

På en Mac med macOS 14+, Xcode Command Line Tools og Homebrew:

```sh
brew install whisper.cpp
./scripts/build-dmg.sh
```

Skriptet bygger for arkitekturen til Macen det kjøres på. Det lager `outputs/Spark-NTNU-macOS-arm64-0.16.0.dmg` på Apple Silicon eller `outputs/Spark-NTNU-macOS-x86_64-0.16.0.dmg` på Intel. Bygg begge variantene på hver sin Mac før en bred utgivelse. Hver DMG er stor fordi modellen ligger inne i appen.

## Signering og notarisering

Uten Developer ID blir pakken ad-hoc signert. macOS kan da vise en sikkerhetsadvarsel, som krever ekstra steg fra brukeren. For en enkel offentlig installasjon, konfigurer Developer ID Application-sertifikat i nøkkelringen og kjør:

```sh
SIGNING_IDENTITY="Developer ID Application: Navn (TEAMID)" \
APPLE_ID="utgiver@example.com" \
APPLE_APP_SPECIFIC_PASSWORD="app-spesifikt-passord" \
APPLE_TEAM_ID="TEAMID" \
./scripts/build-dmg.sh
```

Skriptet signerer appen og DMG-en med hardened runtime, sender DMG-en til Apples notariseringstjeneste og stapler notariseringen. Ikke legg sertifikat, app-passord eller andre signeringshemmeligheter i repoet.

## Publiser

Opprett en GitHub Release for versjonen og last opp begge arkitekturvariantene fra `outputs/`. README-lenken til siste GitHub Release blir da brukerens nedlastingsside. Kontroller at repoet er offentlig før dere deler lenken.

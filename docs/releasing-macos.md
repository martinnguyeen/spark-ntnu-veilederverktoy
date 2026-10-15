# Publisere og oppdatere macOS-appen

## Dette skjer ved en release

Når en `vX.Y.Z`-tag pushes, bygger GitHub Actions macOS-appen for Apple Silicon, pakker med Whisper-modellen, signerer og notariserer appen og DMG-en, lager en EdDSA-signert Sparkle-feed og publiserer filene som en GitHub Release. Den samme jobben støtter **Actions → Release macOS → Run workflow** for å bygge en tag på nytt.

Release-assetene er versjonert DMG og ZIP, `appcast.xml`, og `latest.dmg`/`latest.zip`. Appcast peker på ZIP-en i den versjonerte releasen. DMG-en er for førstegangsinstallasjon; ZIP-en brukes av Sparkle.

## Engangsoppsett i GitHub

Åpne repoets **Settings → Secrets and variables → Actions**.

Den offentlige EdDSA-nøkkelen ligger i `Config/SparklePublicEDKey` og bygges inn i appen. Den er ikke hemmelig og skal følge appen.

Opprett repository secrets:

- `SPARKLE_EDDSA_PRIVATE_KEY`: privat EdDSA-nøkkel eksportert fra Sparkles Keychain-verktøy. Den signerer appcasten. Aldri legg den i Git.
- `APPLE_SIGNING_CERTIFICATE_P12_BASE64`: base64-kodet Developer ID Application-sertifikat med privat nøkkel.
- `APPLE_SIGNING_CERTIFICATE_PASSWORD`: eksportpassordet for sertifikatet.
- `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`: Apple-notarisering.

### Lag Sparkle-nøkkelparet én gang

På en Mac med repoet klonet:

```sh
swift package resolve
SPARKLE_TOOLS="$(find .build/artifacts -type f -name generate_keys -print -quit)"
"$SPARKLE_TOOLS"
```

Den offentlige nøkkelen er allerede lagt inn i `Config/SparklePublicEDKey`. Eksporter den private nøkkelen til en midlertidig fil med Sparkles `generate_keys -x <fil>` og legg filinnholdet inn i `SPARKLE_EDDSA_PRIVATE_KEY`. Slett eksportfilen etter at secret er lagt inn, og oppbevar en sikker offline-kopi. Nøkkelparet opprettes kun én gang; nye versjoner bruker det samme paret.

## Apple-signering og notarisering

Offentlig macOS-distribusjon krever Developer ID Application-sertifikat og Apple-notarisering for en enkel førstegangsinstallasjon. Eksporter sertifikatet med privat nøkkel som `.p12`, base64-kod innholdet og legg det samt passordet inn som GitHub secrets. Ikke committ sertifikat, passord eller Apple app-spesifikt passord.

## Første Sparkle-versjon

Versjon `0.16.0` har ikke Sparkle. Alle som allerede bruker den må installere den første Sparkle-versjonen manuelt én gang, for eksempel `v0.17.0`. Etterpå kan de velge **Se etter oppdateringer** i konto-menyen eller Spark-menyen. Automatisk sjekk er også aktivert.

Sparkle laster ned feed og apparkiv uten GitHub-innlogging. For at testernes apper skal få oppdateringer, må repoet og release-assetene være offentlig tilgjengelige, eller feed og arkiv må hostes offentlig separat. Denne konfigurasjonen endrer ikke repoets synlighet.

## Publisere en ny macOS-versjon

1. Oppdater koden og kontroller at endringen er klar.
2. Lag en semantisk versjonstag, for eksempel `v0.17.0`, og push taggen.
3. Følg **Actions → Release macOS** til den er ferdig.
4. Kontroller GitHub Release: DMG, ZIP, `appcast.xml` og `latest`-lenkene skal ligge der.

CFBundle-versjon og buildnummer settes fra taggen. Behold Sparkle-nøklene uendret på tvers av utgivelser, ellers mister eksisterende installasjoner tillit til oppdateringene.

## Lokal bygging

For å lage en DMG lokalt brukes den offentlige nøkkelen fra `Config/SparklePublicEDKey` automatisk:

```sh
VERSION=0.17.0 ./scripts/build-dmg.sh
```

En lokal ad-hoc signert pakke er for egen bruk. Den erstatter ikke Developer ID-signering og notarisering for testere.

# Audit: Spark NTNU Windows 0.2.0

Dato: 25. september 2026. Gren: `feature/windows-client`.

## Vurdering

**Klar for avgrenset funksjonstesting. Ikke ferdig godkjent for ekte møter eller produksjon.** Første versjon hadde vesentlige forskjeller fra Mac og noen feil som de opprinnelige testene ikke fanget. Punktene nedenfor er rettet i 0.2.0. De viktigste gjenværende portene er fysisk mikrofon/systemlyd i Teams/Zoom/Meet og ekte IDUN-tilkobling over NTNU-nettverket.

Dette er en egenkontroll av kildekode, kjørbar app, avhengigheter og tester, ikke en uavhengig sikkerhetsrevisjon. Mac-sammenligningen bygger på Swift-koden i dette repoet. En kjørende Mac-app var ikke tilgjengelig for visuell sammenligning.

## Funn og rettelser

| Prioritet | Funn i 0.1 | Rettet i 0.2 |
|---|---|---|
| P1 | Gyldige Mac-arkiver kunne avvises: Swift utelater valgfrie `owner`, `deadline` og `confidence`, mens Windows krevde eksplisitte verdier | Arkivleseren godtar Mac-feltene og eldre `point`-navn. Streng validering beholdes for nye IDUN-svar. Regresjonstest lagt til |
| P1 | Åpning/lagring av et arkiv kunne filtrere bort allerede lagrede beslutninger på nytt | Arkivlesing bevarer analysen; filtrering skjer bare ved ny IDUN-analyse |
| P1 | Ingen kontroll av ledig disk under opptak/sluttføring | Kontroll før start, hvert lukket segment og sammenslåing. 128 MiB reserve. Ved feil beholdes lukkede segmenter |
| P1 | Dobbelt oppstartsoppkall kunne opprette flere opptak under asynkron oppstart | Opptaksstart reserverer tilstanden før første ventepunkt. Samtidighetstest verifiserer ett opptak |
| P1 | Skadde segmenter ble sammenføyd uten kontroll av WAV-strukturen | Lukkede WAV-segmenter kontrolleres før gjenoppretting. Skadde originaler beholdes, og brukeren får en feil |
| P2 | Mac-fanene «Møtenotat», «Gjøremål», «Kopier til basen» manglet | Alle tre er lagt til. Basetekst følger Mac-formatet og utelater usikre gjøremål og rå transkripsjon |
| P2 | Kun samlet kopiering av gjøremål | Kopiering av enkeltgjøremål og navigasjon tilbake til kildeutsagn lagt til |
| P2 | Ingen synlig opptakskontroll når hovedvinduet lå i bakgrunnen | Flytende panel med tid, åpne, avbryt og stopp. Testet med minimert hovedvindu og simulert mikrofon. Bakgrunnsbegrensning av rendereren er deaktivert |
| P2 | Windows beholdt rålyd uten tidsfrist, ulikt Mac | Nye vellykkede transkripsjoner får sju dagers frist. Ved oppstart slettes bare kjente lydfiler med gyldig frist; tekst, analyse og avbrutte opptak beholdes. Eldre opptak uten frist slettes ikke automatisk |
| P2 | Oppstartsjekk kunne åpne onboarding selv med installert modell | Førstegangsoppsettet venter på resultatet fra kontroll av lokale filer |
| P2 | Feilmeldinger fra innstillinger kunne skjules bak den åpne dialogen | Status/feil vises også inne i innstillingene |
| P2 | «Avbryt nedlasting» viste manglende modell selv om installasjonen var gyldig | Tilstanden kontrolleres på nytt etter avbrudd |
| P2 | Lokal modell/runtime ble ikke kontrollert for endring etter oppstart | Filfingeravtrykk kontrolleres før transkripsjon. Endringer utløser ny kontrollsumkontroll; ugyldige filer blokkerer kjøring |
| P2 | EXE og vindu brukte Electron-identitet | Original Spark-logo gjenbrukes i ICO og alle ikonressurser i EXE. Vindusikon, Windows AppUserModelID, produktnavn og filbeskrivelse er satt til Spark |
| Lav sikkerhetsgrad | Indirekte `esbuild` 0.27.7 via `tsx` var berørt av utviklingsserver-sårbarhet på Windows | Alle forekomster låst til 0.28.2. Ny `pnpm audit --json`: 0 kjente sårbarheter. Appen bruker ikke en utviklingsserver. [Offisiell advisory](https://github.com/advisories/GHSA-g7r4-m6w7-qqqr) |

## Likhet med Mac

| Område | Status |
|---|---|
| Spark-farger, logo, møtebibliotek, søk, møtedetaljer | Implementert; original Mac-logo brukt. Windows-typografi og native dialoger vil avvike |
| Møtenotat, gjøremål, basetekst, kildehenvisninger, talernavn | Implementert og UI-testet |
| TXT/Markdown/RTF, lydimport, eksport/kopiering/sletting | Implementert. Windows-formatstøtte følger lokal Chromium-dekoding |
| Norsk lokal Whisper, foreløpig/final tekst, gjenoppretting | Implementert. Ekte CPU-runtime og syntetisk norsk lyd testet |
| Opptak i bakgrunnen | Flytende panel lagt til og testet med simulert mikrofon |
| Rålyd etter vellykket transkripsjon | Sju dagers frist for nye opptak. Eksisterende lyd uten metadata beholdes |
| IDUN-instruksjoner og analysefelter | Samme norske systeminstruksjon og modeller; Windows DPAPI erstatter Keychain. Faktisk NTNU-forespørsel gjenstår |
| Systemlyd i møteapper | Kode finnes, men er ennå ikke fysisk godkjent |
| Hurtigdiktering | Lokal transkripsjon og kopier/lim inn fungerer i implementasjonen. Windows mangler Macs automatiske innsetting ved opprinnelig markør og hold/slipp-tast. Snarveien er en bryter: Ctrl+Shift+D |
| Midlertidig diktering | Windows lagrer foreløpig diktering som eget lokalt møte med samme rålydsfrist. Mac behandler dette som midlertidig lyd. Dette er en gjenværende produktforskjell |
| Gjenoppretting ved oppstart | Windows tilbyr en eksplisitt gjenopprett-knapp. Mac forsøker å gjenoppta automatisk |
| Menylinje/systemstatus | Windows har oppgavelinje og flytende panel; separat systemstatusikon tilsvarende Mac-menylinjen er ikke implementert |

## Verifisering

- 28 automatiske domene-/tjenestetester består, inkludert nye tester for Mac-valgfrie felt, uendret arkivinnhold, basetekst, rålydsfrist, samtidige starter og skadd lyd.
- Streng TypeScript-kontroll består.
- Electron-grensesnittet er testet med reell DPAPI, møtebibliotek/søk, faner, kilder, navneendring og JSON import/eksport. Native fil-/bekreftelsesdialoger og utklippstavledata er kontrollert med testdobler; faktisk innliming i andre programmer gjenstår.
- Simulert norsk mikrofon → lukkede WAV-segmenter → live Whisper → minimert hovedvindu → stopp fra flytende panel → ferdig transkripsjon bestod (28,6 sekunder opptak).
- EXE-ressursene er lest tilbake: alle ikongrupper inneholder de originale Spark-PNG-ene i 16, 32, 128 og 256 piksler, og produktnavnet er Spark NTNU.
- Ferdig pakket EXE starter og avslutter korrekt, testet med isolert lokal profil. En eldre Spark-instans var åpen; denne ble ikke avsluttet eller endret.
- Avhengighetskontroll rapporterer 0 kjente sårbarheter etter oppdateringen. Dette er ingen garanti mot ukjente sårbarheter.
- Mac-kildekoden er ikke endret. Ingen brukeropptak eller API-nøkler er brukt i testene.

## Anbefalt neste testøkt

1. Start den nye **0.2.0-pakken**, ikke den gamle EXE-filen. Kontroller Spark-ikon i vindu, oppgavelinje og Filutforsker. Hvis et gammelt festet ikon blir stående, løsne den gamle snarveien og fest den nye pakken.
2. Velg bare mikrofon. Ta opp 30–60 sekunder, minimer Spark, og stopp fra panelet. Bekreft at live-tekst og ferdig tekst er riktige.
3. Test tekstimport, fanene, kildeutsagn, enkeltgjøremål og «Kopier til basen». Test faktisk Ctrl+V i Notepad/Office.
4. Bruk et avtalt testmøte i Teams, Zoom og Meet for **mikrofon + systemlyd**. Kontroller begge stemmer, hodetelefoner, enhetsbytte og tillatelsesavslag. Denne modusen må behandles som eksperimentell inntil dette er bestått.
5. Legg IDUN-nøkkelen direkte inn i appen. Test VPN av/på, bekreft sending av en ufølsom testtranskripsjon og kontroller resultat/kilder. Ikke bruk fortrolige møter før denne testen er bestått.
6. Følg den øvrige sjekklisten i [Windows acceptance](windows-acceptance.md): to timers opptak, hvile/oppvåkning, krasjgjenoppretting, ren brukerkonto og faktisk Mac/Windows-eksport.

Pakken er fortsatt usignert. Ingen publisering eller push til GitHub er gjort i denne gjennomgangen.

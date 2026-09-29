# Spark NTNU for Windows – installasjon og testing

Denne veiledningen gjelder Windows-klienten 0.2.0 på grenen `feature/windows-client`. Målet er å teste installasjon og vanlig bruk på en Windows-maskin. Appen er en usignert testversjon. Lokal transkripsjon er testet automatisk, men fysisk mikrofon, systemlyd og faktisk IDUN-tilkobling må fortsatt verifiseres.

## 1. Før du begynner

- Windows 11 på en Intel/AMD-maskin (x64). Denne pakken støtter ikke Windows ARM.
- Git installert. Skriv `git --version` i PowerShell for å kontrollere. Hvis kommandoen mangler, installer [Git for Windows](https://git-scm.com/download/win), og åpne PowerShell på nytt.
- Internett under installasjonen. Talemodell og runtime er omtrent 470 MiB, i tillegg til byggeverktøy og app. Sett gjerne av minst 3 GB ledig plass til oppsettet og mer til opptak; dette er en praktisk anbefaling, ikke et målt minimum.
- Tilgang til GitHub-repoet dersom det er privat. Fullfør GitHub-innlogging hvis Git ber om det.
- Du trenger ikke installere Node selv eller starte PowerShell som administrator.

**Til den som deler testen:** Del grenen `feature/windows-client`, som inneholder Windows-filene og denne veiledningen. En lokal test er ikke bevis på at installasjonen fra GitHub fungerer; test også kloning og oppsett på en annen Windows-maskin.

Bruk ufølsom testtekst og avtalte testopptak. IDUN er valgfritt og er ikke nødvendig for lokal transkripsjon.

## 2. Installer på en ny testmaskin

Åpne **PowerShell** eller en PowerShell-fane i Windows Terminal. Kjør kommandoene én om gangen. Stopp hvis en kommando feiler.

```powershell
git clone --branch feature/windows-client https://github.com/martinnguyeen/spark-ntnu-veilederverktoy.git
cd spark-ntnu-veilederverktoy
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -ProvisionModel
```

Kjør dette fra en mappe der du har skrivetilgang. Hvis `spark-ntnu-veilederverktoy` allerede finnes, bruk den eksisterende kopien eller velg en annen overordnet mappe.

`-ExecutionPolicy Bypass` gjelder bare PowerShell-prosessen som kjører skriptet; den endrer ikke maskinens permanente policy. Organisasjonens IT-policy kan likevel blokkere kjøring.

Skriptet gjør følgende:

1. Kontrollerer Windows-versjon og arkitektur.
2. Laster ned en fast Node-versjon til din brukerkonto og kontrollerer nedlastingens SHA-256.
3. Installerer låste avhengigheter og Electron.
4. Kjører TypeScript-kontroll og bygger appen.
5. Laster ned og kontrollerer norsk talemodell og Whisper-runtime fordi `-ProvisionModel` er valgt.
6. Pakker appen, skriver ut hvor den ligger og starter den.

**Forventet resultat:** Terminalen skriver `Ferdig. Start appen:` med en filsti, og Spark åpner. Første oppsett kan ta flere minutter. Ikke lukk terminalen mens installasjonen pågår.

API-nøkkel og VPN er ikke nødvendig for dette oppsettet. Hvis modelloppsettet feiler, kan du kjøre kommandoen på nytt. Du kan også bygge uten `-ProvisionModel` og velge **Last ned og klargjør** i appens innstillinger etterpå.

## 3. Test i den lokale kopien som allerede finnes

Hvis du tester utviklingskopien på Martins maskin, trenger du ikke klone på nytt. Lukk en eventuell gammel Spark-app, og kjør:

```powershell
cd 'C:\Users\MartinNguyen\OneDrive - Auticon AS\Skrivebord\Spark - Veilending'
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -ProvisionModel
```

Dette tester lokale filer, inkludert endringer som ennå ikke er pushet. Test også kapittel 2 på en annen maskin før du deler med flere.

## 4. Start appen igjen senere

Appen ligger under:

```text
windows\release\SparkNTNU-win32-x64-<tidsstempel>\Spark NTNU.exe
```

Åpne den nyeste mappen og dobbeltklikk **Spark NTNU.exe**. Behold hele mappen samlet; EXE-filen fungerer ikke alene. Du kan lage en snarvei til EXE-filen.

Lukk den gamle appen før du starter en ny pakke. Spark tillater bare én instans for samme brukerprofil. Hvis oppgavelinjen fortsatt viser et gammelt Electron-ikon, løsne den gamle snarveien og fest den nye appen.

## 5. Første testøkt – kryss av underveis

### A. Oppstart og lokal modell

- [ ] Spark åpner og viser versjon **0.2.0**.
- [ ] Spark-logo vises i appen og som programikon.
- [ ] Åpne innstillingene og velg **Kontroller filer**. Modell og runtime blir godkjent.
- [ ] Lukk appen, og åpne samme EXE igjen. Appen starter uten nytt oppsett.

### B. Mikrofon og transkripsjon

- [ ] Velg bare mikrofon, og start et møte.
- [ ] Snakk norsk i 30–60 sekunder. For eksempel: «Dette er et testmøte. Vi skal prøve Windows-versjonen. Martin skal sende en invitasjon på fredag.»
- [ ] Kontroller at foreløpig tekst dukker opp. Den kan være forsinket og endres ved sluttføring.
- [ ] Minimer hovedvinduet. Et lite opptakspanel med tid og stoppknapp vises.
- [ ] Stopp fra panelet, og vent på ferdig transkripsjon.
- [ ] Møtet ligger i biblioteket, og teksten gjengir det som ble sagt rimelig godt.
- [ ] Start appen på nytt og kontroller at møtet fortsatt finnes.

### C. Bibliotek, import og kopiering

- [ ] Gi testmøtet et nytt navn, og finn det med søk.
- [ ] Lagre en kort, ufølsom tekstfil i Notepad, og importer den i Spark.
- [ ] Eksporter et testmøte som JSON og importer filen igjen. Det skal komme inn som et eget møte.
- [ ] Prøv kopiering av transkripsjon og lim inn i Notepad med **Ctrl+V**. Faktisk innliming i andre apper må kontrolleres manuelt.
- [ ] Slett bare det importerte testmøtet, og kontroller at originalen er bevart.

### D. IDUN og møteanalyse – krever egen tilgang

Denne delen krever en IDUN API-nøkkel og tilkobling til eduroam eller NTNU VPN. Uten dette kan du fortsatt teste lokal transkripsjon og biblioteket.

- [ ] Koble til NTNU-nett/VPN, og legg nøkkelen direkte inn i appens innstillinger. Ikke legg den i terminalen eller repoet.
- [ ] Test nøkkelen i innstillingene.
- [ ] Åpne et ufølsomt testmøte og velg **Oppsummer møte**.
- [ ] Kontroller bekreftelsen før sending. Bare transkripsjon og metadata skal sendes til IDUN; lyd behandles lokalt.
- [ ] Kontroller fanene **Møtenotat**, **Gjøremål** og **Kopier til basen** når analysen er ferdig.
- [ ] Åpne en kildehenvisning og kontroller den mot transkripsjonen.
- [ ] Kopier ett gjøremål og baseteksten, og lim inn i Notepad. Innholdet skal stemme med møtet.
- [ ] Test uten VPN hvis maskinen heller ikke er på NTNU-nett. Eventuell tilkoblingsfeil skal vises uten at møtet forsvinner.

### E. Systemlyd – separat test før ekte møter

- [ ] Avtal et kort testmøte i Teams, Zoom eller Meet, og bruk hodetelefoner.
- [ ] Velg **+ systemlyd** i Spark, og start opptak.
- [ ] La både deg og den andre deltakeren snakke tydelig etter tur.
- [ ] Stopp, og kontroller at begge stemmene er med i teksten.
- [ ] Gjenta for hver møteapp dere faktisk skal bruke.

Systemlyd kan inkludere andre apper og varsler. Modusen er ikke ferdig fysisk verifisert. Hvis bare din egen stemme kommer med, er denne testen ikke bestått selv om mikrofontesten fungerer.

### F. Hurtigdiktering

- [ ] Trykk **Ctrl+Shift+D**, si en kort setning, og trykk snarveien igjen for å stoppe.
- [ ] Vent på ferdig tekst og følg appens kopieringsbeskjed. Lim inn i Notepad med **Ctrl+V**.

Windows bruker en av/på-snarvei og manuell innliming. Macs hold/slipp-tast og automatisk innsetting ved markøren er ikke implementert. Diktering lagres foreløpig som et lokalt møte.

## 6. Oppdater en testinstallasjon

Det finnes ikke automatisk oppdatering. Når en ny versjon er pushet, lukk Spark og kjør fra repo-mappen:

```powershell
git switch feature/windows-client
git pull --ff-only
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -ProvisionModel
```

Stopp hvis Git melder konflikt eller lokale endringer; ikke slett dem for å komme videre. Den nye pakken får en ny mappe under `windows\release`. Oppdater snarveien din til denne. Møtene ligger utenfor repoet og beholdes ved vanlig gjenbygging.

## 7. Vanlige problemer

| Problem | Hva du gjør |
|---|---|
| `git` gjenkjennes ikke | Installer Git for Windows og åpne terminalen på nytt. |
| `Repository not found` eller innloggingsfeil | Kontroller GitHub-konto og tilgang til repoet. Fullfør innloggingen Git åpner. |
| Grenen finnes ikke, eller installasjonsskriptet mangler | Windows-grenen og filene er ikke tilgjengelige i kopien du har. Den som deler testen må pushe dem først. |
| Nedlasting eller installasjon feiler | Ta vare på den første feilmeldingen. Kontroller internett og ledig disk, og prøv installasjonskommandoen igjen. Ved kontrollsumfeil skal kontrollen ikke fjernes. |
| Windows eller bedriftens policy blokkerer appen | Appen er usignert. Avklar tillatt kjøring med IT; ikke slå av antivirus eller organisasjonens beskyttelse. |
| Ny app ser ut som gammel versjon | Lukk den kjørende Spark-appen først, og åpne EXE-filen fra den nye pakken. |
| Ingen tale i teksten | Kontroller valgt standardmikrofon i Windows, og at mikrofontilgang for skrivebordsapper er tillatt under Windows-innstillingene for personvern. Prøv mikrofon alene først. |
| Modell mangler | Velg **Last ned og klargjør**, deretter **Kontroller filer** i appens innstillinger. |
| IDUN virker ikke | Kontroller nøkkelen og NTNU-nett/VPN. Lokal transkripsjon skal kunne brukes uavhengig av IDUN. |
| Avbrutt opptak | Åpne møtet og velg **Gjenopprett / prøv CPU-transkripsjon igjen**. Det siste uferdige segmentet, opptil 15 sekunder, kan være tapt. |

En enkel kontroll uten installasjon kan kjøres fra repo-mappen:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -CheckOnly
```

Dette viser grunnleggende oppsettstatus. Det erstatter ikke modellkontrollen eller testene over.

## 8. Data og tilbakemelding

Møter, lyd, modell og beskyttet API-nøkkel lagres i `%LOCALAPPDATA%\SparkNTNU`. Byggeverktøy ligger i `%LOCALAPPDATA%\SparkNTNU-Tools`. Rålyd fra nye, vellykkede transkripsjoner får sju dagers frist og ryddes ved oppstart etter fristen; tekst og analyse beholdes. Avbrutte opptak og eldre lyd uten frist beholdes.

Ved feil, oppgi:

- Appversjon og Windows-versjon (kjør `winver`).
- Hvilket punkt i testlisten som feilet.
- Hva du gjorde, forventet resultat og faktisk resultat.
- Feilmelding eller skjermbilde uten API-nøkkel eller fortrolige møtedata.
- Om du brukte mikrofon, systemlyd, hodetelefoner og hvilken møteapp.

Begynn med 2–3 testere. Før bredere distribusjon gjenstår blant annet ren installasjon på en annen maskin, fysisk lyd/IDUN, lange opptak, hvile/oppvåkning og krasjgjenoppretting. Se [auditrapporten](docs/windows-audit-2026-09-25.md), [utvidet testliste](docs/windows-acceptance.md) og [teknisk Windows-dokumentasjon](windows/README.md).

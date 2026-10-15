# Jobbe med Windows-versjonen fra en annen enhet

Windows-koden er tilgjengelig på `main` i dette repoet. Du kan redigere den og kjøre typesjekk, portable tester og bygging på Mac, Linux eller Windows. Windows-appen, lydopptak, DPAPI og EXE-installasjonen må kjøres og testes på Windows. GitHub Actions kan bygge EXE-filen for deg, også når du jobber fra Mac.

## Hent koden

Installer Git og Node.js 22.23.3 (samme versjon som CI), og kjør:

```sh
git clone https://github.com/martinnguyeen/spark-ntnu-veilederverktoy.git
cd spark-ntnu-veilederverktoy
git switch -c feature/windows-min-endring
cd windows
npx --yes pnpm@11.25.0 install --frozen-lockfile --ignore-scripts
npm run typecheck
node --import tsx --test tests/core.test.ts
npm run build
```

Har du allerede en lokal kopi, kjør `git status` først. Ta vare på lokale endringer før du bytter gren. Hent så siste `main` med `git switch main` og `git pull --ff-only`, og opprett en ny arbeidsgren derfra.

Klon hele repoet: `windows/` bruker felles logoer fra `Assets/` og kontrakter fra `docs/shared-contracts/`. Ikke kopier `node_modules` fra en annen maskin; installer avhengighetene på hver enhet.

## Hvor ligger filene?

| Mappe/fil | Innhold |
|---|---|
| `windows/src/` | Hele Windows-appen: grensesnitt, opptak, lokal transkripsjon, lagring og IDUN |
| `windows/scripts/` | Bygging, pakking, EXE-installasjon og testverktøy |
| `windows/scripts/install-windows.ps1` | Windows-oppsett fra kildekoden |
| `windows/tests/` | Automatiske tester og syntetisk testlyd |
| `windows/package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml` | Avhengigheter, versjoner og kommandoer |
| `.github/workflows/windows.yml` | GitHub Actions; må ligge her for at GitHub skal finne den |
| `docs/shared-contracts/`, `Assets/` | Ressurser som deles med Mac-versjonen |

Den gamle `scripts/install-windows.ps1` er kun en videresending, slik at tidligere delte installasjonskommandoer fortsatt fungerer. Genererte filer i `windows/dist/`, `windows/release/` og `windows/node_modules/` skal ikke sjekkes inn. Møter, modellfiler og API-nøkler skal heller ikke i Git.

## Bygg en EXE via GitHub fra hvilken som helst enhet

1. Gjør endringene dine, kjør kontrollene ovenfor og commit dem.
2. Push arbeidsgrenen: `git push -u origin feature/windows-min-endring`.
3. Åpne [Actions → Windows client](https://github.com/martinnguyeen/spark-ntnu-veilederverktoy/actions/workflows/windows.yml). Endringer under `windows/` starter automatisk en kjøring. Du kan også velge **Run workflow** og riktig gren manuelt.
4. Vent til både Windows-jobben og de portable kontrollene er grønne.
5. Åpne kjøringen og last ned **Spark-NTNU-Windows-x64-…** under **Artifacts**. GitHub leverer en ZIP som inneholder `Spark-NTNU-Windows-x64-0.2.0-Setup.exe`.
6. Pakk ut ZIP-filen og test EXE-filen på Windows 11 x64. Filen er usignert. Artefakten oppbevares i 14 dager og krever GitHub-tilgang for nedlasting.

Dette publiserer ikke en ny GitHub Release og endrer ikke den offentlige nedlastingslenken automatisk. Det gir deg en testfil fra akkurat den commit-en du bygget. Opprett en pull request til `main` når endringen er klar.

## Kjør og pakk lokalt på Windows

Fra `windows/`, etter installasjon av avhengighetene:

```powershell
node node_modules/electron/install.js
npm run build
npm start
```

For en komplett installasjonsfil:

```powershell
npm run installer
```

Alternativt kan du kjøre oppsettet fra repo-roten:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\scripts\install-windows.ps1 -ProvisionModel
```

På Mac/Linux: bruk `typecheck`, tester og `build`, og la GitHub Actions gjøre Windows-pakkingen. RTF-testen hoppes over uten Windows. Ikke bruk `npm start`, `package`, `installer`, modellprovisjonering eller opptakstestene for å validere Windows-oppførsel på et annet operativsystem.

Følg [den manuelle testlisten](../README-WINDOWS.md) for fysisk lyd, møteapper og IDUN før en ny versjon deles bredt.

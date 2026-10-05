# Spark NTNU for Windows

For norsk trinnvis installasjon og manuell testing, se [README for Windows](../README-WINDOWS.md). This document covers technical setup and implementation details.

Electron/TypeScript Windows-only client. The existing Swift macOS application stays unchanged.

## Build and run

To create the per-user Windows installer after installing dependencies, run `npm run installer`. This rebuilds the app and writes `release/installer/Spark-NTNU-Windows-x64-0.2.0-Setup.exe`. The installer includes all app files, adds Start menu/desktop shortcuts and an uninstaller, and leaves meeting data intact on uninstall. The speech model is downloaded in the app. This test installer is unsigned.

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

This uses Node 22.23.3, pnpm 11.25.0, the frozen `pnpm-lock.yaml`, Electron 44.4.5, and TypeScript. Tools live in `%LOCALAPPDATA%\SparkNTNU-Tools`. The executable is printed by the installer under `windows/release/SparkNTNU-win32-x64-<timestamp>/Spark NTNU.exe`. Keep the complete folder together; no Node installation is needed to launch that built folder. It is a developer package, not a signed installer.

`-NoLaunch` builds without opening a window. `-CheckOnly` reports setup state without installing. `-ProvisionModel` provisions the same verified model/runtime from the command line; the normal app offers the download interactively. Installing/building dependencies uses internet but does not require NTNU VPN or administrator access.

With Node on PATH, from `windows/`:

```powershell
npx --yes pnpm@11.25.0 install --frozen-lockfile --ignore-scripts
node node_modules/electron/install.js
npm run typecheck
npm test
npm run build
npm start
npm run package
```

## Using Spark

- Open Settings and choose **Last ned og klargjør**. The approximately 465 MiB Norwegian model and 4 MiB CPU runtime come from their official sources. Pause preserves partial data; cancel discards partial downloads; retry resumes where supported. SHA-256 is checked before installation. Allow at least 650 MB for speech assets, plus application and recording space.
- **Start møte** records the microphone. **+ systemlyd** also requests Windows loopback; this captures the selected system output, including other apps and notifications. Spark produces no audible playback of its capture stream. The Chromium-required video track is immediately stopped and never written or sent through IPC. Hardware verification of this mode is still required.
- Closed 15-second WAV segments are written atomically. Live text is provisional; the entire saved recording is transcribed again on stop. If CPU transcription falls behind, live segments may be skipped; the final transcript still processes all saved audio.
- **Ctrl+Shift+Space** toggles meeting recording. **Ctrl+Shift+D** toggles dictation. Dictation uses the clipboard fallback and explicitly instructs **Ctrl+V** at the desired cursor. There is no automatic focus stealing/paste injection. Stop and cancel buttons are also available.
- Import TXT, Markdown, RTF, JSON meetings, WAV, MP3, M4A, FLAC, OGG or WebM. Audio decoding is local, limited to formats supported by Chromium, 250 MB and two hours per imported file. RTF uses the built-in Windows RichTextBox decoder. UTF-8 and Windows-1252 text are supported.
- Search local meetings, rename a meeting or speaker, open evidence links, copy notes/actions, export Markdown/JSON, delete one or all meetings. Imported JSON gets a new UUID to avoid overwrites.
- IDUN is optional. Add/test/replace/remove the API key in Settings. **Oppsummer møte** opens a native confirmation explaining exactly what leaves the PC. Only transcript text and metadata are sent directly to `https://llm.hpc.ntnu.no/v1/chat/completions`. Connect to eduroam or NTNU VPN first. No Spark proxy or remote speech fallback exists.
- Meeting detection is opt-in per launch, examines window titles without thumbnails, and only proposes recording. It never records automatically.

## Data and recovery

`%LOCALAPPDATA%\SparkNTNU` contains `Meetings/<UUID>/meeting.json`, independent WAV segments and a finalized WAV; `Models/<revision>/ggml-model.bin`; `Runtime/<version>` and its verified archive; and `idun-key.dpapi`. The directory does not use Windows Roaming AppData. Electron's own profile/cache also lives here.

After an interruption, reopen the meeting and choose **Gjenopprett / prøv CPU-transkripsjon igjen**. The last unclosed segment (up to 15 seconds) may be lost. Sleep requests stop/finalization on a best-effort basis; closed segments remain recoverable if Windows suspends the process before completion. Recording prevents ordinary app suspension while active.

Close Spark before backing up the folder to a user-chosen local drive. Exporting JSON/Markdown includes transcript and analysis, not audio; use a folder backup to include audio. The DPAPI key is bound to the Windows account and machine and is not a portable credential backup. No automatic sync or backup upload is implemented. Version 0.2 removes raw audio seven days after successful transcription, checked on startup; transcript and analysis remain. Interrupted recordings and older recordings without valid expiry metadata are preserved. Deleting a meeting removes its audio too. Removing the model keeps meetings and key intact.

## Security boundary

Renderer: sandboxed, context isolation, Node disabled, strict CSP (`connect-src 'none'`), navigation/popups denied. Narrow preload operations invoke main-process handlers that validate the sender frame and local page URL. Paths are selected with OS dialogs or derived from validated UUIDs. Audio IPC accepts bounded PCM arrays, not executable paths. Credentials never return to the renderer and are encrypted with Windows DPAPI; other programs running as the same Windows user remain inside the threat boundary. IDUN redirects are rejected to avoid forwarding the key. Runtime errors omit process stderr because it may contain transcript text. No diagnostic upload exists.

## Tests

`npm test` covers download verification/resume/errors/space checks, meeting persistence and evidence validation, recovery/cancellation, text/RTF import, model routing, and the IDUN request boundary using stubs. `npm run test:ui` launches an isolated test archive and tests the actual Electron UI and DPAPI; native file/confirmation dialogs and clipboard payload are stubbed.

Opt-in real CPU and simulated-microphone tests, using a separate local data folder:

```powershell
$env:SPARK_TEST_DATA = Join-Path $env:LOCALAPPDATA 'SparkNTNU-DevelopmentAcceptance'
node --import tsx scripts/provision.mts
node --import tsx scripts/acceptance.mts
node scripts/capture-smoke.mjs
```

`capture-smoke.mjs` uses Chromium's fake microphone and the synthetic Norwegian test WAV, never your physical microphone. Test folder overrides are disabled in packaged builds. See [acceptance report](../docs/windows-acceptance.md) for remaining real-device checks.

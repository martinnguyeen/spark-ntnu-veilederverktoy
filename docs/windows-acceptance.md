# Windows implementation and acceptance report

Initial tests: 2026-09-24; final verification: 2026-09-25. Branch: `feature/windows-client`.

## Delivery status

Updated by the [0.2.0 audit](windows-audit-2026-09-25.md): 28 tests, Mac-style detail tabs/base copy, floating recording controls, Spark EXE branding, improved archive compatibility, disk checks and seven-day raw-audio expiry for new successful transcriptions. The original results below document the initial delivery; the audit contains the latest findings.

Implemented an Electron/TypeScript developer client under `windows/` and a one-command per-user PowerShell setup. The source builds and produces a runnable Windows folder. The macOS sources are unchanged. The technical spike's local CPU path is proven; release go/no-go is still **pending** physical loopback/microphone and network acceptance below. An unsigned developer build is not a production release.

## Target machine recorded

| Item | Observed |
|---|---|
| OS | Windows 11 Pro x64, build 26200 |
| CPU | Intel Core Ultra 5 225U |
| RAM | 16,017,846,272 bytes (about 15 GiB) |
| GPU | Intel Graphics; driver 32.0.101.8826 |
| Baseline | CPU-only Whisper with `-ng`, Norwegian `-l no` |
| Microphone/headset | Not accessed during automated tests; select and record during physical acceptance |
| Free disk space | Checked dynamically by downloader; available in Settings → Diagnostics |

Do not infer minimum hardware or support for all Windows 11 builds from this one machine.

## Implemented scope

Spark colors (#f28c1c, #1a1a1a, #fafaf8, #e8e6e1, #fdf0dc), sidebar/recording card, meeting library/detail, summary/decisions/actions/questions/evidence, Norwegian copy, rounded cards, keyboard focus, reduced-motion support, and provisional transcript panel follow the existing SwiftUI source. Visual inspection was performed on screenshots of the running Electron app. This is source-based design parity; no side-by-side running Mac screenshot comparison has been claimed.

Local microphone capture, loopback mode, final/live CPU transcription, dictation clipboard fallback, text/audio import, recovery, local search/export/deletion, opt-in meeting prompts, DPAPI key management, and explicit direct-to-IDUN analysis are implemented. Whisper assets are pinned, resumable, verified and stored outside Git. First-run key setup is optional and separate from model setup.

## Automated checks performed locally

| Check | Result |
|---|---|
| TypeScript strict typecheck and bundled build | Passed |
| 21 domain/service tests | Passed, including import disk-failure recovery |
| Official model/runtime download and SHA-256 | Passed; 487,601,984-byte model and 4,386,743-byte CPU runtime archive |
| Reuse of verified assets | Passed; no redownload needed |
| Norwegian synthetic audio → real Whisper CPU | Passed; 3 transcript segments, exact fixture text, 4.991 seconds in initial run |
| Fake microphone → WebAudio → 15-second closed WAV → live Whisper → final Whisper | Passed; initial 21-second recording and final 30.2-second regression run, nonempty Norwegian transcript |
| Actual Electron onboarding/library/search/evidence/rename | Passed |
| DPAPI key add/remove | Passed; stored bytes do not contain plaintext test key |
| JSON export/import | Passed through actual app handlers with OS file dialogs stubbed |
| IDUN consent cancellation | Passed; stored meeting remains unchanged |
| IDUN request validation | Passed with stubs; fixed endpoint, no audio field, no request without confirmation |
| Clipboard button payload | Passed with a stub. Real OS clipboard readback is unavailable in this automation environment; direct PowerShell Set/Get-Clipboard also returned empty |
| PowerShell developer setup | Passed on this account: fresh per-user Node install, frozen dependencies, build and package |
| Packaged EXE launch and normal window shutdown | Passed; production profile uses `%LOCALAPPDATA%\SparkNTNU` |
| RTF decoding | Passed using the local Windows decoder |
| Closed-segment recovery after a new service instance | Passed |

Synthetic audio is checked in at `windows/tests/fixtures/norwegian-synthetic.wav`. It uses the local Microsoft Jon voice and contains no human microphone recording. Download failure cases use deterministic network stubs; a full real-network disconnect/low-disk soak is not claimed. Windows CI is checked in but has not run on GitHub until this branch is pushed.

## Physical acceptance checklist — still required

Use Settings → Diagnostics to note free space and app version. Enter your real IDUN key directly in the app, not in source or this report.

- [ ] Fresh Windows user/VM: execute setup with no Node/model/runtime, start packaged app, complete download; relaunch without redownload. Record installation time and total app/model disk use.
- [ ] Pause midway, close/reopen, resume, disconnect/reconnect internet, corrupt a test model, simulate low disk; verify actionable errors and successful retry. Never use real meeting data for fault injection.
- [ ] Physical microphone/headset: denial then permission grant, Norwegian speech, stop/finalize, device unplug/change, accurate elapsed time and recording indicator.
- [ ] Teams, Zoom and Google Meet: remote participant plus local mic, both source levels, no screen files, no unwanted local monitoring; confirm prompts never auto-start recording.
- [ ] Loopback capture with actual output devices. Chromium grants a temporary video track which is stopped immediately; confirm system audio remains live after stopping that track on this device. If this fails, implement/validate native WASAPI before release.
- [ ] 120-minute recording, CPU load, memory growth, sleep/wake, forced process termination, recovery and low-disk behavior. Check the documented loss of only the last unclosed segment.
- [ ] Dictation and shortcuts from other apps; paste into Notepad, browser and Office. Clipboard fallback is implemented; automatic cursor insertion is not.
- [ ] Real IDUN test with VPN off/on; explicit confirmation, key replace/remove, valid summary and evidence, retry after failure. Inspect traffic to confirm raw audio never leaves the device.
- [ ] Real Mac JSON export → Windows import → Windows export → Mac decode. Unit fixtures match the Mac contract but do not replace a live interoperability test.
- [ ] Keyboard-only navigation, high DPI, long titles, Windows screen reader, reduced motion and sidebar layout at minimum window size.

## Follow-on release work

Resolve the physical gates before declaring Electron a production go. Code signing/installer/update distribution and validated GPU acceleration are outside this developer delivery. The CPU baseline deliberately avoids a GPU dependency. Version 0.2 schedules seven-day raw-audio expiry after successful transcription; interrupted recordings and older audio without valid expiry metadata are preserved.

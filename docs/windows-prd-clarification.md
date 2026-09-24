# Spark NTNU for Windows — PRD and clarification brief

**Status:** Working draft. Product direction, first test target, and first delivery shape are confirmed; the test PC's hardware details and cross-platform record portability remain open.

**Purpose:** Turn the existing macOS app into a Windows version in the same GitHub repository, and give the Windows PC owner a clear test plan. This document is for implementation planning; it does not prescribe the Windows UI framework before a short technical spike.

## Decisions confirmed by the product owner

- Keep the macOS app and add the Windows app in the **same repository**.
- Windows v1 should aim for **feature parity with the current Mac app**, not only a Whisper demo.
- Download the speech model automatically on first use, with visible progress, pause/resume, and retry.
- First test target: **Windows 11 x64**.
- First delivery shape: a **PowerShell developer setup script** in the repository, for testing on the owner's PC.
- Local Norwegian speech recognition is a core requirement. Audio must not silently fall back to a remote transcription service.

## User problem

NTNU supervisors need the Spark meeting workflow on Windows as well as macOS. A first-time user should be able to install the app, obtain its local transcription runtime and Norwegian speech model without hunting for files or running developer tools, then record and transcribe locally. Meeting analysis through IDUN remains an explicit, user-confirmed network action.

## Product goals

1. Let a Windows user install and start Spark without manually finding a Whisper model or runtime.
2. Preserve the local-first audio and transcription boundary from the Mac app.
3. Provide the current meeting, dictation, import, recovery, and IDUN analysis workflows on Windows.
4. Keep Mac and Windows in one repository while preserving the existing Mac app.
5. Use the Windows PC as a real-device test target before treating Windows support as released.

## Current codebase: verified constraints

- The current application is a Swift Package targeting macOS 14+, with a SwiftUI interface.
- The project uses macOS-only APIs including AppKit, AVFoundation, ScreenCaptureKit, Security/Keychain, and `/usr/bin/afconvert`. These parts cannot simply be built as a Windows app.
- Local transcription uses the `whisper.cpp` command-line program and the `NbAiLab/nb-whisper-small-beta` model. The current model file is 465 MB; its verified SHA-256 is `35b3f1e98355c5cf80ca261a2b44934edd9ea94aa1104725d563e16dbb4e7b0b`.
- The transcript segment contract is `{ id, start, end, speaker, text }`. Meetings and analysis results are persisted as JSON. These are candidates for a platform-neutral contract, but cross-platform file compatibility needs an explicit test.
- IDUN analysis sends transcript text only after the user asks to analyze the meeting. The Mac stores its API key in Keychain. Windows needs its own secure credential-store implementation.
- The GitHub repository should contain source and a small model manifest, not the 465 MB model, users' recordings, API keys, or built app bundles.

## Recommended repository shape

Preserve the current macOS project in place for the first Windows implementation. Add a clearly separated Windows client and platform-neutral product contracts:

```text
Sources/Ordlyd/                 # existing macOS app; avoid churn during Windows work
windows/                         # Windows app and Windows-specific tests
scripts/install-macos.sh
scripts/install-windows.ps1      # one-command developer setup for the test PC
docs/shared-contracts/           # JSON schemas, prompts, model manifest, fixture notes
docs/windows-prd-clarification.md
```

Treat “same codebase” as **same repository and same product contracts** for the first release. Reuse stable model identifiers, transcript/meeting JSON contracts, IDUN request/response examples, validation rules, prompt text, and test fixtures where practical. Do not make Windows depend on AppKit, ScreenCaptureKit, or macOS Keychain. A small implementation spike should decide whether any pure domain code can be extracted and shared; feature parity must not be blocked on a full UI rewrite.

## Feature scope: Windows parity

Windows v1 is intended to cover the capabilities already present on macOS. Each platform must use native APIs where required while preserving the same user-visible behavior and safety boundaries.

| Capability | Windows requirement | Notes for implementation |
|---|---|---|
| Meeting library and detail | Browse, search, reopen, export, and delete meetings | Preserve transcript, summary, decisions, actions, questions, and evidence links |
| Microphone meeting capture | Record microphone audio locally | Show recording state and elapsed time; recover closed audio segments after an interrupted session |
| Microphone + system audio | Capture both sources when the user selects the mode | Use and validate the supported Windows loopback capture path; exclude Spark's own output where possible |
| Live transcription | Refresh a provisional transcript while recording | Reuse local Whisper and make the in-progress state clear; finalize text on stop |
| Full transcription | Transcribe a completed or imported audio file locally | Norwegian language; report missing/corrupt model or runtime without uploading audio |
| Dictation | Capture speech, transcribe locally, then insert at the cursor or copy as a fallback | Provide an appropriate Windows shortcut and explain any Windows permission required |
| Text and audio import | Import supported text and audio formats | Normalize audio locally to the format required by Whisper |
| Meeting app detection | Offer the same explicit start prompt for supported Teams, Zoom, and Meet contexts | Detection must never start recording automatically |
| IDUN analysis | Request meeting analysis only after user confirmation | NTNU eduroam/VPN access; send transcript text, not raw audio |
| API key management | Add, test, remove, and replace the key | Store through a Windows secure credential facility; never put secrets in JSON or logs |
| Local meeting data | Save and delete meeting data on the PC | Define data folder, backup/export behavior, and cross-platform JSON compatibility |
| Progress and recovery | Show real task state, elapsed time, errors, and retry options | Do not display invented percentage completion for IDUN requests |

## P0: first-run Whisper setup

The Whisper download/install experience is a release-blocking requirement.

1. On first transcription, check for the pinned `whisper.cpp` runtime and the expected model file.
2. If either is missing, offer a clear setup step that identifies what will be downloaded and the approximate disk space required. The model alone is about 465 MB; the runtime and temporary download space also need to be included in the estimate.
3. Download the model from the official project model source over HTTPS. Keep the source URL, model ID, expected size, version/revision, and SHA-256 together in a checked-in manifest.
4. Show useful byte-based progress and allow pause/cancel. Resume an interrupted download where the source permits it. Provide retry and an understandable offline/network error.
5. Download to a temporary file, verify SHA-256, and only then move it atomically to the final per-user model location. Never run a partial or unverified model file.
6. Avoid administrator permissions for model storage; prefer the current user's application-data directory. Do not put a 465 MB model in Git or require the user to choose a file manually for the normal path.
7. Check free disk space before starting. State clearly that model setup can use ordinary internet and does not require eduroam/VPN; IDUN analysis separately requires NTNU network/VPN access.
8. Provide a Settings/Diagnostics action to recheck, retry, repair, or remove the local model. Removing the model must not remove meetings or the API key.
9. Pin a compatible `whisper.cpp` Windows runtime too. The model file by itself is insufficient. Normal users must not need Homebrew, a Visual Studio developer shell, or CMake just to install/run the released app.
10. Make CPU-only transcription a supported baseline. Hardware acceleration may be enabled when detected and validated, but a GPU/backend failure must fall back safely or offer a clear CPU retry; it must never crash the app.

## Privacy and security requirements

- Microphone and system audio stay on the PC during recording, segmentation, recovery, and transcription.
- Never upload raw audio or automatically switch to a hosted speech-recognition service.
- Before IDUN analysis, state that transcript text will be sent to NTNU IDUN and require explicit confirmation.
- Require eduroam or NTNU VPN for IDUN, with a recoverable network error and a way to retry after connecting.
- Store the API key in Windows Credential Manager or an equivalent OS-protected store. Redact it from diagnostics and logs.
- Ask for recording permissions at the point of use, show an unmistakable recording indicator, and require a user action before capture begins.
- Keep recordings, transcript data, and model files outside the repository and out of diagnostic uploads.

## Proposed Windows onboarding

1. Welcome and explain that transcription runs locally.
2. Check/download the pinned Whisper runtime and model with progress, cancel, resume, and retry.
3. Confirm that local transcription is ready with a short optional microphone/model check.
4. Offer the NTNU IDUN API-key step separately. Link to the key request page and explain eduroam/VPN. Model download must remain available even if the user has not obtained a key yet.
5. Request microphone/system-audio access only when the user first chooses the related recording mode.

## Acceptance criteria

### Clean Windows installation

- On a clean supported Windows PC with no Whisper files, one documented setup path installs/builds the app and provisions the runtime and model.
- The setup path does not require users to search for a model download, copy a file into a hidden directory, install Homebrew, or enter an administrator password for per-user assets.
- A second launch recognizes the valid model and does not download it again.

### Model download resilience

- Progress reflects actual bytes; pause/cancel and resume/retry work.
- Interrupted, insufficient-space, offline, HTTP error, and checksum mismatch cases are understandable and recoverable.
- A corrupted or incomplete file is never accepted as installed; the final file appears only after checksum verification.
- Downloading the model works without the NTNU VPN. IDUN's VPN requirement is shown separately.

### Local speech workflow

- Given the checked-in, consented test audio, Windows produces a non-empty Norwegian transcript locally.
- Network inspection/test stubs confirm no audio upload or hosted-ASR fallback occurs.
- Microphone-only, microphone plus system audio, live provisional transcription, stop/finalize, and imported audio are tested on the actual Windows PC.
- An unavailable GPU/runtime falls back to a supported CPU path or gives a clear retry; no unhandled process crash.

### Meeting workflow and safety

- Windows can create, reopen, search, export, and delete meeting records using the documented JSON contract.
- App detection only displays a prompt; it never starts recording by itself.
- IDUN sends transcript text only after confirmation, stores the API key securely, and succeeds when eduroam/VPN is connected.
- Unsupported or denied microphone/system-audio permissions explain how to recover.

## Windows test plan

Use the owner's Windows PC as the first hardware acceptance target, then add a clean Windows VM/device for installation tests.

- Record Windows edition/build, CPU architecture, CPU model, RAM, free disk space, GPU model/driver, and microphone/headset before choosing acceleration or minimum specs.
- Test a fresh install with no runtime/model, a valid existing model, a partial download, bad checksum, no internet, low disk space, and retry after network restoration.
- Test CPU-only transcription first; then validate any supported acceleration on this PC.
- Test microphone capture and system loopback separately in Teams, Zoom, and Meet, including device changes and permission denial.
- Test a long recording, sleep/wake or app interruption, recovery of closed segments, dictation cursor insertion, clipboard fallback, and every global shortcut.
- Test IDUN with VPN off/on; verify audio stays local and only confirmed transcript text is sent.
- Add Windows-specific CI tests for domain/JSON/model-manifest logic where possible. Keep physical audio/meeting-app checks as explicit manual gates.

## Open questions before the implementation plan is locked

1. **Test PC hardware:** CPU model, RAM, free storage, and GPU model/driver. (Needed to set minimum specs and decide if acceleration is in scope.)
2. **Cross-platform records:** Should a meeting created on macOS be openable on Windows by copying/exporting its data, and vice versa? There is no cloud-sync requirement established here.
3. **Minimum Windows build:** Record the Windows 11 build on the test PC during the spike, then use tested support rather than assuming every Windows 11 release works.

## Implementation handoff

After the open questions are answered, produce a short Windows technical spike before implementation. It should prove: Windows builds the chosen UI framework; the pinned `whisper.cpp` runtime loads this exact model; a CPU-only sample transcription works; model download/resume/checksum works; the IDUN request uses the existing request/response contract; and microphone plus system loopback capture can be implemented with the target PC's APIs. Then turn the results into a phased implementation plan and test checklist.

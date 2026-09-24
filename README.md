# Spark NTNU – veilederverktøy

Native macOS app for local Norwegian meeting transcription and transcript-based meeting notes with NTNU IDUN.

## Install from source

Requirements: macOS 14 or newer, an internet connection during setup, and enough disk space for the approximately 466 MB Norwegian speech model. The installer checks for Apple's Command Line Tools and Homebrew, installs `whisper.cpp`, downloads and verifies the model, then builds the app for the Mac's processor (Apple Silicon or Intel).

1. Clone or download this repository from GitHub.
2. In Terminal, change into the project folder and run:

   ```sh
   ./scripts/install-macos.sh
   ```

If Apple's Command Line Tools are missing, the script opens their macOS installer. Complete that prompt and run the command again. If Homebrew is missing, the script runs Homebrew's official installer. The script prints the app path and an `open` command when it finishes. The model is stored locally at `~/Library/Application Support/Ordlyd/Models/nb-whisper-small-beta/ggml-model.bin`; the installer checks its SHA-256 before using it.

Check the current machine's setup without installing or downloading anything:

```sh
./scripts/install-macos.sh --check-only
```

## First launch

Spark asks for an NTNU IDUN API key. Request a key at [ai.hpc.ntnu.no/request-api-key](https://ai.hpc.ntnu.no/request-api-key), while connected to eduroam or NTNU VPN, then paste it into onboarding. The key is stored in macOS Keychain. IDUN requests also require an active NTNU network or VPN connection.

Microphone and system-audio capture require the corresponding macOS permissions. The app keeps audio and local transcription on the Mac; only the transcript is sent to IDUN after the user confirms meeting analysis.

## Development

```sh
swift run Ordlyd
swift test
```

The project uses Swift Package Manager and has no external Swift package dependencies. `whisper.cpp` and the speech model are installed separately by the setup script.

## Windows version

The Windows app is planned for this same repository. The [Windows PRD and clarification brief](docs/windows-prd-clarification.md) records the confirmed scope, platform-specific constraints, first-run Whisper setup requirements, acceptance criteria, and remaining questions before a Windows technical spike.

## Distribution

The setup script builds the app locally and ad-hoc signs it. To distribute a prebuilt `.app` to users as a conventional GitHub download, configure Developer ID signing and Apple notarization for the release. This repository does not include a `LICENSE` file yet; choose a license before inviting others to reuse or contribute code. Do not commit API keys, local meeting data, model files, or build artifacts to this repository.

## Speech model

- Model: [NbAiLab/nb-whisper-small-beta](https://huggingface.co/NbAiLab/nb-whisper-small-beta)
- Runtime: [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- Model license: CC BY 4.0, National Library of Norway AI Lab

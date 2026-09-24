#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Spark NTNU veilederverktøy"
VERSION="0.16.0"
BUILD="16"
MODEL_DIR="$HOME/Library/Application Support/Ordlyd/Models/nb-whisper-small-beta"
MODEL_PATH="$MODEL_DIR/ggml-model.bin"
MODEL_URL="https://huggingface.co/NbAiLab/nb-whisper-small-beta/resolve/main/ggml-model.bin"
MODEL_SHA256="35b3f1e98355c5cf80ca261a2b44934edd9ea94aa1104725d563e16dbb4e7b0b"
CHECK_ONLY=0

if [[ "${1:-}" == "--check-only" ]]; then CHECK_ONLY=1; fi

fail() { printf '\nFEIL: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Dette installasjonsprogrammet krever macOS."
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
(( MACOS_MAJOR >= 14 )) || fail "Spark krever macOS 14 eller nyere. Denne maskinen har macOS $MACOS_VERSION."

if ! xcode-select -p >/dev/null 2>&1; then
    say "Installerer Apples Command Line Tools. Følg dialogen som åpnes, og kjør dette skriptet på nytt når installasjonen er ferdig."
    xcode-select --install || true
    exit 2
fi

command -v swift >/dev/null 2>&1 || fail "Swift mangler. Installer Xcode Command Line Tools med: xcode-select --install"
command -v curl >/dev/null 2>&1 || fail "curl mangler."
command -v shasum >/dev/null 2>&1 || fail "shasum mangler."

if ! command -v brew >/dev/null 2>&1; then
    (( CHECK_ONLY == 0 )) || fail "Homebrew mangler. Installer fra https://brew.sh, og kjør sjekken på nytt."
    say "Installerer Homebrew fra den offisielle installasjonsadressen. Homebrew kan be om macOS-passordet ditt."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    if [[ -x /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
fi
command -v brew >/dev/null 2>&1 || fail "Homebrew ble ikke tilgjengelig etter installasjonen. Følg Homebrew-instruksjonene for skallet ditt, og kjør skriptet på nytt."

if [[ -f "$MODEL_PATH" ]] && [[ "$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')" == "$MODEL_SHA256" ]]; then
    MODEL_STATUS="NB-Whisper-modellen er allerede installert og kontrollert."
else
    MODEL_STATUS="NB-Whisper-modellen lastes ned (omtrent 466 MB)."
fi

if (( CHECK_ONLY )); then
    printf 'Klar for macOS %s (%s).\n' "$MACOS_VERSION" "$(uname -m)"
    printf 'Swift: %s\nHomebrew: %s\nWhisper CLI: ' "$(swift --version | head -1)" "$(brew --version | head -1)"
    if command -v whisper-cli >/dev/null 2>&1; then command -v whisper-cli; else printf 'installeres med Homebrew\n'; fi
    printf '%s\n' "$MODEL_STATUS"
    exit 0
fi

say "Installerer lokal transkripsjonsmotoren whisper.cpp"
brew list --versions whisper.cpp >/dev/null 2>&1 || brew install whisper.cpp
WHISPER_BIN="$(brew --prefix whisper.cpp)/bin/whisper-cli"
[[ -x "$WHISPER_BIN" ]] || WHISPER_BIN="$(command -v whisper-cli || true)"
[[ -n "$WHISPER_BIN" && -x "$WHISPER_BIN" ]] || fail "Homebrew installerte ikke whisper-cli som forventet."

if [[ ! -f "$MODEL_PATH" ]] || [[ "$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')" != "$MODEL_SHA256" ]]; then
    say "Laster ned NB-Whisper-modellen til Application Support"
    mkdir -p "$MODEL_DIR"
    TEMP_MODEL="$MODEL_DIR/ggml-model.bin.download"
    rm -f "$TEMP_MODEL"
    curl --fail --location --retry 3 --output "$TEMP_MODEL" "$MODEL_URL" || { rm -f "$TEMP_MODEL"; fail "Nedlasting av modellen feilet. Kontroller nettverket og prøv igjen."; }
    ACTUAL_SHA256="$(shasum -a 256 "$TEMP_MODEL" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA256" != "$MODEL_SHA256" ]]; then
        rm -f "$TEMP_MODEL"
        fail "Modellfilens SHA-256 stemte ikke. Ingen modell ble installert. Kontakt utgiveren før du prøver en annen fil."
    fi
    mv "$TEMP_MODEL" "$MODEL_PATH"
fi

say "Bygger Spark for $(uname -m)"
cd "$ROOT"
swift build -c release --product Ordlyd

APP="$ROOT/outputs/$APP_NAME.app"
STAGING="$ROOT/outputs/.Spark-staging.app"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$ROOT/.build/release/Ordlyd" "$STAGING/Contents/MacOS/Ordlyd"
cp "$ROOT/Assets/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"
cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Spark* NTNU - veilederverktøy</string>
<key>CFBundleExecutable</key><string>Ordlyd</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>no.ordlyd.app</string>
<key>CFBundleName</key><string>Spark NTNU veilederverktøy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Spark bruker mikrofonen for lokal diktering og møtetranskripsjon.</string>
<key>NSScreenCaptureUsageDescription</key><string>Spark kan ta opp systemlyd fra møter når du velger dette.</string>
</dict></plist>
PLIST
chmod +x "$STAGING/Contents/MacOS/Ordlyd"
codesign --force --deep --sign - "$STAGING"
rm -rf "$APP"
mv "$STAGING" "$APP"

say "Fullført"
printf 'App: %s\n' "$APP"
printf 'Lokal Whisper-modell: %s\n' "$MODEL_PATH"
printf 'Whisper CLI: %s\n' "$WHISPER_BIN"
printf '\nÅpne appen med:\nopen "%s"\n' "$APP"
printf '\nMerk: denne lokale byggingen er ad-hoc signert. Offentlig nedlasting av en utgitt app krever Developer ID-signering og Apple-notarisering.\n'

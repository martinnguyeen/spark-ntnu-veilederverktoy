#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '\nFEIL: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
APP_NAME="Spark NTNU veilederverktøy"
VERSION="${VERSION:-0.16.0}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Versjonen må være semantisk versjonering som 0.17.0."
IFS=. read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH <<< "$VERSION"
BUILD="${BUILD:-$((10#$VERSION_MAJOR * 1000000 + 10#$VERSION_MINOR * 1000 + 10#$VERSION_PATCH))}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(tr -d '[:space:]' < "$ROOT/Config/SparklePublicEDKey")}"
[[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || fail "SPARKLE_PUBLIC_ED_KEY mangler. Sett den offentlige Sparkle-nøkkelen før du bygger en DMG som skal kunne oppdateres."
MODEL_SHA256="35b3f1e98355c5cf80ca261a2b44934edd9ea94aa1104725d563e16dbb4e7b0b"
MODEL_URL="https://huggingface.co/NbAiLab/nb-whisper-small-beta/resolve/main/ggml-model.bin"
MODEL_CACHE="$ROOT/.build/release-assets/ggml-model.bin"
OUTPUT_DIR="$ROOT/outputs"
STAGING="$OUTPUT_DIR/.dmg-staging"
APP="$STAGING/$APP_NAME.app"
FRAMEWORKS="$APP/Contents/Frameworks"
BACKENDS="$FRAMEWORKS/ggml-backends"
RESOURCES="$APP/Contents/Resources"
ARCH="$(uname -m)"

[[ "$(uname -s)" == "Darwin" ]] || fail "DMG-byggingen krever macOS."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail "Spark krever macOS 14 eller nyere."
command -v swift >/dev/null 2>&1 || fail "Swift mangler. Installer Apples Command Line Tools først."
command -v brew >/dev/null 2>&1 || fail "Homebrew mangler. Installer Homebrew først."
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil mangler."

WHISPER_PREFIX="$(brew --prefix whisper.cpp 2>/dev/null)" || fail "whisper.cpp mangler. Kjør brew install whisper.cpp først."
GGML_PREFIX="$(brew --prefix ggml 2>/dev/null)" || fail "ggml-bibliotekene mangler. Installer whisper.cpp på nytt med Homebrew."
OMP_PREFIX="$(brew --prefix libomp 2>/dev/null)" || fail "libomp mangler. Installer whisper.cpp på nytt med Homebrew."
WHISPER_BIN="$WHISPER_PREFIX/bin/whisper-cli"
[[ -x "$WHISPER_BIN" ]] || fail "Fant ikke whisper-cli i $WHISPER_PREFIX."

MODEL_PATH="$HOME/Library/Application Support/Ordlyd/Models/nb-whisper-small-beta/ggml-model.bin"
if [[ ! -f "$MODEL_PATH" ]] || [[ "$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')" != "$MODEL_SHA256" ]]; then
    mkdir -p "$(dirname "$MODEL_CACHE")"
    say "Laster ned NB-Whisper-modellen (omtrent 466 MB)"
    curl --fail --location --retry 3 --progress-bar --output "$MODEL_CACHE" "$MODEL_URL" || fail "Nedlasting av modellen feilet. Kontroller nettverket og prøv igjen."
    [[ "$(shasum -a 256 "$MODEL_CACHE" | awk '{print $1}')" == "$MODEL_SHA256" ]] || fail "Modellfilens kontrollsum stemmer ikke."
    MODEL_PATH="$MODEL_CACHE"
fi

say "Bygger Spark for $ARCH"
cd "$ROOT"
swift build -c release --product Ordlyd

rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS" "$FRAMEWORKS" "$BACKENDS" "$RESOURCES"
cp "$ROOT/.build/release/Ordlyd" "$APP/Contents/MacOS/Ordlyd"
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"
[[ -n "$SPARKLE_FRAMEWORK" ]] || fail "Fant ikke Sparkle.framework etter bygging. Kontroller Swift Package Manager-avhengigheten."
cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
LOAD_COMMANDS="$(otool -l "$APP/Contents/MacOS/Ordlyd")"
if [[ "$LOAD_COMMANDS" != *'@executable_path/../Frameworks'* ]]; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Ordlyd"
fi
cp "$ROOT/Assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$MODEL_PATH" "$RESOURCES/ggml-model.bin"
cp "$WHISPER_BIN" "$FRAMEWORKS/whisper-cli"
cp "$(find "$WHISPER_PREFIX/lib" -maxdepth 1 -name 'libwhisper.1*.dylib' -print -quit)" "$FRAMEWORKS/libwhisper.1.dylib"
cp "$(find "$GGML_PREFIX/lib" -maxdepth 1 -name 'libggml.0*.dylib' -print -quit)" "$FRAMEWORKS/libggml.0.dylib"
cp "$(find "$GGML_PREFIX/lib" -maxdepth 1 -name 'libggml-base.0*.dylib' -print -quit)" "$FRAMEWORKS/libggml-base.0.dylib"
cp "$(find "$OMP_PREFIX/lib" -maxdepth 1 -name 'libomp*.dylib' -print -quit)" "$FRAMEWORKS/libomp.dylib"
if [[ "$ARCH" == "arm64" ]]; then
    CPU_BACKEND="$GGML_PREFIX/libexec/libggml-cpu-apple_m1.so"
else
    CPU_BACKEND="$(find "$GGML_PREFIX/libexec" -maxdepth 1 -name 'libggml-cpu*.so' -print -quit)"
fi
[[ -f "$CPU_BACKEND" ]] || fail "Fant ingen kompatibel CPU-backend for $ARCH i Homebrew-installasjonen."
cp "$CPU_BACKEND" "$BACKENDS/"
chmod u+w "$FRAMEWORKS"/*.dylib "$FRAMEWORKS/whisper-cli" "$BACKENDS"/*.so

for dylib in "$FRAMEWORKS"/*.dylib; do
    name="$(basename "$dylib")"
    install_name_tool -id "@loader_path/$name" "$dylib"
done
install_name_tool -change "@rpath/libwhisper.1.dylib" "@loader_path/libwhisper.1.dylib" "$FRAMEWORKS/whisper-cli"
install_name_tool -change "$WHISPER_PREFIX/lib/libwhisper.1.dylib" "@loader_path/libwhisper.1.dylib" "$FRAMEWORKS/whisper-cli" 2>/dev/null || true
install_name_tool -change "$GGML_PREFIX/lib/libggml.0.dylib" "@loader_path/libggml.0.dylib" "$FRAMEWORKS/whisper-cli"
install_name_tool -change "$GGML_PREFIX/lib/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FRAMEWORKS/whisper-cli"
install_name_tool -change "$GGML_PREFIX/lib/libggml.0.dylib" "@loader_path/libggml.0.dylib" "$FRAMEWORKS/libwhisper.1.dylib"
install_name_tool -change "$GGML_PREFIX/lib/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FRAMEWORKS/libwhisper.1.dylib"
install_name_tool -change "@rpath/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FRAMEWORKS/libggml.0.dylib"
install_name_tool -change "@rpath/libomp.dylib" "@loader_path/libomp.dylib" "$FRAMEWORKS/libggml-base.0.dylib"
for backend in "$BACKENDS"/*.so; do
    install_name_tool -change "@rpath/libggml-base.0.dylib" "@loader_path/../libggml-base.0.dylib" "$backend"
    install_name_tool -change "$OMP_PREFIX/lib/libomp.dylib" "@loader_path/../libomp.dylib" "$backend" 2>/dev/null || true
done

cat > "$APP/Contents/Info.plist" <<PLIST
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
<key>SUFeedURL</key><string>https://github.com/martinnguyeen/spark-ntnu-veilederverktoy/releases/latest/download/appcast.xml</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Spark bruker mikrofonen for lokal diktering og møtetranskripsjon.</string>
<key>NSScreenCaptureUsageDescription</key><string>Spark kan ta opp systemlyd fra møter når du velger dette.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Ordlyd" "$FRAMEWORKS/whisper-cli"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$FRAMEWORKS"/*.dylib "$FRAMEWORKS/whisper-cli" "$BACKENDS"/*.so
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$FRAMEWORKS/Sparkle.framework"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$OUTPUT_DIR"
ln -sfn /Applications "$STAGING/Applications"
DMG="$OUTPUT_DIR/Spark-NTNU-macOS-$ARCH-$VERSION.dmg"
ZIP="$OUTPUT_DIR/Spark-NTNU-macOS-$ARCH-$VERSION.zip"
rm -f "$DMG"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
        xcrun stapler validate "$APP"
        spctl --assess --type execute --verbose "$APP"
    else
        printf '\nADVARSEL: Appen er signert, men ikke notarisiert. Sett APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD og APPLE_TEAM_ID for notariseringssteget.\n' >&2
    fi
fi

hdiutil create -quiet -volname "Spark NTNU" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
else
    printf '\nADVARSEL: DMG-en er ad-hoc signert. macOS kan kreve at brukeren godkjenner appen i Systeminnstillinger > Personvern og sikkerhet.\n' >&2
fi

rm -rf "$STAGING"
printf '\nDMG ferdig: %s\n' "$DMG"
printf 'Sparkle-oppdateringsarkiv: %s\n' "$ZIP"
printf 'Arkitektur: %s\n' "$ARCH"
printf 'Størrelse: '
du -h "$DMG" | awk '{print $1}'

#!/bin/bash
# Builds "Disc Image Studio.app" with the disc engine CLI bundled inside it.
# Usage: scripts/build-app.sh [osx-arm64|osx-x64]     (defaults to this Mac's architecture)
# Needs Xcode's command line tools and the .NET 10 SDK. Output goes to dist/.
set -euo pipefail

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$mac_dir/../.." && pwd)"
if [[ $# -ge 1 ]]; then
  rid="$1"
elif [[ "$(uname -m)" == "arm64" ]]; then
  rid="osx-arm64"
else
  rid="osx-x64"
fi
case "$rid" in
  osx-arm64) swift_arch="arm64" ;;
  osx-x64) swift_arch="x86_64" ;;
  *) echo "Unknown runtime '$rid'. Use osx-arm64 or osx-x64." >&2; exit 2 ;;
esac

version="$(sed -n 's:.*<VersionPrefix>\(.*\)</VersionPrefix>.*:\1:p' "$repo_root/Directory.Build.props")"
app="$mac_dir/dist/Disc Image Studio.app"
contents="$app/Contents"
resources="$contents/Resources"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$resources/cli" "$resources/Catalogs"

echo "==> Building the Swift app ($swift_arch)"
swift build --package-path "$mac_dir" -c release --arch "$swift_arch"
bin_path="$(swift build --package-path "$mac_dir" -c release --arch "$swift_arch" --show-bin-path)"
cp "$bin_path/DiscImageStudioMac" "$contents/MacOS/Disc Image Studio"

echo "==> Publishing the disc engine ($rid)"
dotnet publish "$repo_root/src/DiscImageStudio.Cli/DiscImageStudio.Cli.csproj" \
  -c Release -r "$rid" --self-contained true -o "$mac_dir/.build/cli-$rid" \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -v quiet
cp "$mac_dir/.build/cli-$rid/disc-image-studio" "$resources/cli/disc-image-studio"

echo "==> Adding resources"
cp "$repo_root"/src/DiscImageStudio.App/Localization/Catalogs/*.json "$resources/Catalogs/"
cp "$mac_dir"/Catalogs/*.json "$resources/Catalogs/"
# GPL distribution: the license and notices must travel with the binary.
cp "$repo_root/LICENSE" "$repo_root/THIRD-PARTY-NOTICES.txt" "$repo_root/LICENSE-NOTICE.md" "$resources/"

iconset="$mac_dir/.build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
source_icon="$repo_root/src/DiscImageStudio.App/Assets/DiscImageStudio-256.png"
for size in 16 32 128 256; do
  sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"

cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Disc Image Studio</string>
  <key>CFBundleDisplayName</key><string>Disc Image Studio</string>
  <key>CFBundleIdentifier</key><string>io.github.discimagestudio.mac</string>
  <key>CFBundleExecutable</key><string>Disc Image Studio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Disc Image Studio Project</string>
      <key>CFBundleTypeExtensions</key><array><string>discproj</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Signing for local use (ad hoc, not notarized)"
codesign --force --sign - "$resources/cli/disc-image-studio"
codesign --force --sign - "$app"

echo "Built: $app"

#!/bin/zsh
set -euo pipefail

# Assemble an ad-hoc signed local bundle from an already-built debug binary.
# This is for TCC development only; release packaging still uses
# package-app.sh followed by the Developer ID release lane.

script_directory="${0:A:h}"
macos_root="${script_directory:h}"
binary_directory="$macos_root/.build/arm64-apple-macosx/debug"
output_root="$macos_root/.build/local-app"
bundle_path="$output_root/Menso.app"

executable_path="$binary_directory/MensoApp"
sparkle_framework="$binary_directory/Sparkle.framework"
webrtc_framework="$binary_directory/WebRTC.framework"
cua_driver="$macos_root/Resources/CuaDriver/cua-driver"

for required_file in \
  "$executable_path" \
  "$macos_root/Resources/Info.plist" \
  "$macos_root/Resources/PrivacyCopy.json" \
  "$macos_root/Resources/CuaDriver/manifest.json" \
  "$macos_root/Resources/CuaDriver/session-policy.yaml" \
  "$cua_driver"
do
  [[ -e "$required_file" ]] || { print -u2 "missing debug bundle input: $required_file"; exit 66; }
done
for required_framework in "$sparkle_framework" "$webrtc_framework"; do
  [[ -d "$required_framework" ]] \
    || { print -u2 "missing debug framework: $required_framework"; exit 66; }
done

rm -rf "$bundle_path"
mkdir -p \
  "$bundle_path/Contents/MacOS" \
  "$bundle_path/Contents/Frameworks" \
  "$bundle_path/Contents/Helpers" \
  "$bundle_path/Contents/Resources/CuaDriver"

cp "$executable_path" "$bundle_path/Contents/MacOS/MensoApp"
cp "$macos_root/Resources/Info.plist" "$bundle_path/Contents/Info.plist"
cp "$macos_root/Resources/PrivacyCopy.json" "$bundle_path/Contents/Resources/PrivacyCopy.json"
cp "$macos_root/Resources/CuaDriver/manifest.json" "$bundle_path/Contents/Resources/CuaDriver/manifest.json"
cp "$macos_root/Resources/CuaDriver/session-policy.yaml" "$bundle_path/Contents/Resources/CuaDriver/session-policy.yaml"
cp "$cua_driver" "$bundle_path/Contents/Helpers/cua-driver"
ditto "$sparkle_framework" "$bundle_path/Contents/Frameworks/Sparkle.framework"
ditto "$webrtc_framework" "$bundle_path/Contents/Frameworks/WebRTC.framework"

chmod 755 "$bundle_path/Contents/MacOS/MensoApp" "$bundle_path/Contents/Helpers/cua-driver"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$bundle_path/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$bundle_path/Contents/Frameworks/WebRTC.framework"
/usr/bin/codesign --force --sign - --timestamp=none \
  "$bundle_path/Contents/Helpers/cua-driver"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  --entitlements "$macos_root/Menso.entitlements" \
  "$bundle_path"

print "$bundle_path"

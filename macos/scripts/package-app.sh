#!/bin/zsh
set -euo pipefail

# Bundle assembly only. Building, signing, notarizing, and stapling are separate,
# explicitly authorized release steps. Invoke with an already-built executable
# and the Sparkle/WebRTC binary artifacts emitted by SwiftPM. The reviewed CUA
# executable must already have been fetched with fetch-cua-driver.sh.

if [[ $# -ne 4 ]]; then
  print -u2 "usage: $0 /absolute/path/to/MensoApp /absolute/path/to/Sparkle.framework /absolute/path/to/WebRTC.framework /absolute/output/directory"
  exit 64
fi

executable_path="$1"
sparkle_framework_path="$2"
webrtc_framework_path="$3"
output_directory="$4"
script_directory="${0:A:h}"
macos_root="${script_directory:h}"
bundle_path="${output_directory}/Menso.app"
cua_resource_root="$macos_root/Resources/CuaDriver"
cua_driver_path="$cua_resource_root/cua-driver"

if [[ ! -f "$executable_path" ]]; then
  print -u2 "Menso executable not found: $executable_path"
  exit 66
fi

if [[ ! -d "$sparkle_framework_path" ]]; then
  print -u2 "Sparkle framework not found: $sparkle_framework_path"
  exit 66
fi

if [[ ! -d "$webrtc_framework_path" ]]; then
  print -u2 "WebRTC framework not found: $webrtc_framework_path"
  exit 66
fi

if [[ ! -x "$cua_driver_path" ]]; then
  print -u2 "pinned CUA Driver is missing; run scripts/fetch-cua-driver.sh first"
  exit 66
fi

if [[ ! -f "$macos_root/Resources/AppIcon.icns" ]]; then
  print -u2 "Release app icon is missing: $macos_root/Resources/AppIcon.icns"
  exit 78
fi

mkdir -p \
  "$bundle_path/Contents/MacOS" \
  "$bundle_path/Contents/Resources/CuaDriver" \
  "$bundle_path/Contents/Frameworks" \
  "$bundle_path/Contents/Helpers"
cp "$executable_path" "$bundle_path/Contents/MacOS/MensoApp"
cp "$macos_root/Resources/Info.plist" "$bundle_path/Contents/Info.plist"
cp "$macos_root/Resources/PrivacyCopy.json" "$bundle_path/Contents/Resources/PrivacyCopy.json"
cp "$cua_resource_root/manifest.json" "$bundle_path/Contents/Resources/CuaDriver/manifest.json"
cp "$cua_resource_root/session-policy.yaml" "$bundle_path/Contents/Resources/CuaDriver/session-policy.yaml"
cp "$cua_driver_path" "$bundle_path/Contents/Helpers/cua-driver"
ditto "$sparkle_framework_path" "$bundle_path/Contents/Frameworks/Sparkle.framework"
ditto "$webrtc_framework_path" "$bundle_path/Contents/Frameworks/WebRTC.framework"
cp "$macos_root/Resources/AppIcon.icns" "$bundle_path/Contents/Resources/AppIcon.icns"

chmod 755 "$bundle_path/Contents/MacOS/MensoApp"
chmod 755 "$bundle_path/Contents/Helpers/cua-driver"

print "$bundle_path"

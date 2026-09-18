#!/bin/zsh
set -euo pipefail

# Source-only release contract. It intentionally performs no build or dependency
# resolution. Give it an already assembled app whose Sparkle and WebRTC
# frameworks have been copied with symlinks intact by package-app.sh.

if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 /absolute/path/to/Menso.app /absolute/release/directory"
  exit 64
fi

app_path="$1"
release_directory="$2"
script_directory="${0:A:h}"
macos_root="${script_directory:h}"
info_plist="$app_path/Contents/Info.plist"
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
webrtc_framework="$app_path/Contents/Frameworks/WebRTC.framework"
cua_driver="$app_path/Contents/Helpers/cua-driver"
cua_manifest="$app_path/Contents/Resources/CuaDriver/manifest.json"
cua_session_policy="$app_path/Contents/Resources/CuaDriver/session-policy.yaml"
appcast_template="$macos_root/Resources/appcast.xml.template"

require_release_value() {
  local variable_name="$1"
  local variable_value="$2"
  if [[ -z "$variable_value" ]]; then
    print -u2 "missing required release variable: $variable_name"
    exit 78
  fi
}

require_release_value MENSO_DEVELOPER_ID_APPLICATION "${MENSO_DEVELOPER_ID_APPLICATION:-}"
require_release_value MENSO_NOTARY_KEY_ID "${MENSO_NOTARY_KEY_ID:-}"
require_release_value MENSO_NOTARY_ISSUER_ID "${MENSO_NOTARY_ISSUER_ID:-}"
require_release_value MENSO_NOTARY_KEY_PATH "${MENSO_NOTARY_KEY_PATH:-}"
require_release_value MENSO_SPARKLE_FEED_URL "${MENSO_SPARKLE_FEED_URL:-}"
require_release_value MENSO_SPARKLE_DOWNLOAD_URL_PREFIX "${MENSO_SPARKLE_DOWNLOAD_URL_PREFIX:-}"
require_release_value MENSO_SPARKLE_PUBLIC_ED_KEY "${MENSO_SPARKLE_PUBLIC_ED_KEY:-}"
require_release_value MENSO_SPARKLE_PRIVATE_ED_KEY_PATH "${MENSO_SPARKLE_PRIVATE_ED_KEY_PATH:-}"
require_release_value MENSO_SPARKLE_GENERATE_APPCAST "${MENSO_SPARKLE_GENERATE_APPCAST:-}"
require_release_value MENSO_RELEASE_VERSION "${MENSO_RELEASE_VERSION:-}"
require_release_value MENSO_RELEASE_BUILD "${MENSO_RELEASE_BUILD:-}"

if [[ ! -d "$app_path" || ! -f "$info_plist" ]]; then
  print -u2 "assembled Menso app is missing or malformed: $app_path"
  exit 66
fi
if [[ ! -d "$sparkle_framework" ]]; then
  print -u2 "embedded Sparkle.framework is missing: $sparkle_framework"
  exit 66
fi
if [[ ! -d "$webrtc_framework" ]]; then
  print -u2 "embedded WebRTC.framework is missing: $webrtc_framework"
  exit 66
fi
if [[ ! -x "$cua_driver" || ! -f "$cua_manifest" || ! -f "$cua_session_policy" ]]; then
  print -u2 "pinned embedded CUA Driver resources are missing"
  exit 66
fi
if [[ ! -f "$app_path/Contents/Resources/AppIcon.icns" ]]; then
  print -u2 "release app icon is missing from the bundle"
  exit 66
fi
if [[ ! -x "$MENSO_SPARKLE_GENERATE_APPCAST" ]]; then
  print -u2 "Sparkle generate_appcast is not executable: $MENSO_SPARKLE_GENERATE_APPCAST"
  exit 66
fi
if [[ ! -f "$MENSO_SPARKLE_PRIVATE_ED_KEY_PATH" ]]; then
  print -u2 "Sparkle private Ed25519 key file is unavailable"
  exit 66
fi
if [[ ! -f "$MENSO_NOTARY_KEY_PATH" ]]; then
  print -u2 "App Store Connect notarization API key is unavailable"
  exit 66
fi
if [[ "$MENSO_SPARKLE_FEED_URL" != https://* || "$MENSO_SPARKLE_DOWNLOAD_URL_PREFIX" != https://* ]]; then
  print -u2 "Sparkle feed and download URLs must use HTTPS"
  exit 78
fi
if [[ "$MENSO_SPARKLE_FEED_URL" == *['&<>|']* ]]; then
  print -u2 "Sparkle feed URL contains characters unsupported by the appcast template"
  exit 78
fi
if [[ "$MENSO_RELEASE_VERSION" != <->.<->.<-> || \
      "$MENSO_RELEASE_BUILD" != <-> || \
      "$MENSO_RELEASE_BUILD" == "0" ]]; then
  print -u2 "release version must be X.Y.Z and build must be a positive integer"
  exit 78
fi

public_key_bytes="$(print -rn -- "$MENSO_SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d ' ' || true)"
if [[ "$public_key_bytes" != "32" ]]; then
  print -u2 "MENSO_SPARKLE_PUBLIC_ED_KEY is not a 32-byte base64 Ed25519 public key"
  exit 78
fi

mkdir -p "$release_directory"
release_directory="${release_directory:A}"
archive_directory="$release_directory/archive"
updates_directory="$release_directory/updates"
staging_directory="$release_directory/dmg-root"
mkdir -p "$archive_directory" "$updates_directory" "$staging_directory"

/usr/libexec/PlistBuddy -c "Set :SUFeedURL $MENSO_SPARKLE_FEED_URL" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $MENSO_SPARKLE_PUBLIC_ED_KEY" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MENSO_RELEASE_VERSION" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MENSO_RELEASE_BUILD" "$info_plist"

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$info_plist")" != "true" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$info_plist")" != "true" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :SUSignedFeedFailureExpirationInterval' "$info_plist")" != "0" ]]; then
  print -u2 "strict signed-feed and pre-extraction verification must remain enabled"
  exit 78
fi

short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
if [[ -z "$short_version" || -z "$bundle_version" ]]; then
  print -u2 "bundle versions are required for Sparkle ordering"
  exit 78
fi

# Sparkle's binary distribution includes nested helpers. Sign inside-out and do
# not use --deep, preserving the Downloader service entitlement where present.
/bin/zsh "$script_directory/cua-driver-integrity.sh" verify-input "$app_path"
sparkle_version_root="$sparkle_framework/Versions/B"
for nested_bundle in \
  "$sparkle_version_root/XPCServices/Installer.xpc" \
  "$sparkle_version_root/XPCServices/Downloader.xpc" \
  "$sparkle_version_root/Autoupdate" \
  "$sparkle_version_root/Updater.app"; do
  if [[ -e "$nested_bundle" ]]; then
    if [[ "$nested_bundle" == */Downloader.xpc ]]; then
      codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
        --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$nested_bundle"
    else
      codesign --force --timestamp --options runtime \
        --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$nested_bundle"
    fi
  fi
done
codesign --force --timestamp --options runtime \
  --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$sparkle_framework"
codesign --force --timestamp --options runtime \
  --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$webrtc_framework"
codesign --force --timestamp --options runtime \
  --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$cua_driver"
/bin/zsh "$script_directory/cua-driver-integrity.sh" record-signed "$app_path"
codesign --force --timestamp --options runtime --entitlements "$macos_root/Menso.entitlements" \
  --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$app_path"

archive_zip="$archive_directory/Menso-${short_version}-${bundle_version}.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_zip"
xcrun notarytool submit "$archive_zip" --wait \
  --key "$MENSO_NOTARY_KEY_PATH" \
  --key-id "$MENSO_NOTARY_KEY_ID" \
  --issuer "$MENSO_NOTARY_ISSUER_ID"
xcrun stapler staple "$app_path"

ditto "$app_path" "$staging_directory/Menso.app"
ln -sfn /Applications "$staging_directory/Applications"
dmg_path="$updates_directory/Menso-${short_version}-${bundle_version}.dmg"
hdiutil create -quiet -fs APFS -format ULFO \
  -volname "Menso ${short_version}" \
  -srcfolder "$staging_directory" \
  -ov "$dmg_path"
codesign --force --timestamp --sign "$MENSO_DEVELOPER_ID_APPLICATION" "$dmg_path"
xcrun notarytool submit "$dmg_path" --wait \
  --key "$MENSO_NOTARY_KEY_PATH" \
  --key-id "$MENSO_NOTARY_KEY_ID" \
  --issuer "$MENSO_NOTARY_ISSUER_ID"
xcrun stapler staple "$dmg_path"

if [[ ! -f "$updates_directory/appcast.xml" ]]; then
  cp "$appcast_template" "$updates_directory/appcast.xml"
  /usr/bin/sed -i '' "s|__MENSO_SPARKLE_FEED_URL__|$MENSO_SPARKLE_FEED_URL|g" \
    "$updates_directory/appcast.xml"
fi
"$MENSO_SPARKLE_GENERATE_APPCAST" \
  --ed-key-file "$MENSO_SPARKLE_PRIVATE_ED_KEY_PATH" \
  --download-url-prefix "$MENSO_SPARKLE_DOWNLOAD_URL_PREFIX" \
  --output-path "$updates_directory/appcast.xml" \
  "$updates_directory"

if ! /usr/bin/grep -q 'sparkle:edSignature=' "$updates_directory/appcast.xml"; then
  print -u2 "generated appcast has no Ed25519 archive signature"
  exit 70
fi

print "release artifacts: $updates_directory"

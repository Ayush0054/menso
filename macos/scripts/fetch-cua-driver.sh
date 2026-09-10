#!/bin/zsh
set -euo pipefail

# Fetches one reviewed CUA Driver release before any signing credential is
# materialized. The binary itself is intentionally not committed. Its release
# archive is authenticated by the exact SHA-256 published for v0.12.6, then the
# nested executable is signed by Menso's release lane.

script_directory="${0:A:h}"
macos_root="${script_directory:h}"
manifest_path="$macos_root/Resources/CuaDriver/manifest.json"
output_path="${1:-$macos_root/Resources/CuaDriver/cua-driver}"

archive_url="$(/usr/bin/plutil -extract archive_url raw -o - "$manifest_path")"
archive_sha256="$(/usr/bin/plutil -extract archive_sha256 raw -o - "$manifest_path")"
binary_sha256="$(/usr/bin/plutil -extract binary_sha256 raw -o - "$manifest_path")"
version="$(/usr/bin/plutil -extract version raw -o - "$manifest_path")"

if [[ "$archive_url" != https://github.com/trycua/cua/releases/download/cua-driver-rs-v*/* ]]; then
  print -u2 "CUA archive URL is outside the reviewed GitHub release path"
  exit 78
fi
if (( ${#archive_sha256} != 64 || ${#binary_sha256} != 64 )) \
  || [[ "$archive_sha256$binary_sha256" == *[^0-9a-f]* ]]; then
  print -u2 "CUA archive SHA-256 is malformed"
  exit 78
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/menso-cua.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
archive_path="$temporary_directory/cua-driver.tar.gz"
extract_path="$temporary_directory/extracted"
mkdir -p "$extract_path"

/usr/bin/curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 \
  "$archive_url" -o "$archive_path"
actual_sha256="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha256" != "$archive_sha256" ]]; then
  print -u2 "CUA archive checksum mismatch"
  exit 78
fi

/usr/bin/tar -xzf "$archive_path" -C "$extract_path"
binary_path="$extract_path/cua-driver-rs-${version}-darwin-arm64/cua-driver"
if [[ ! -f "$binary_path" ]]; then
  print -u2 "expected the reviewed cua-driver path in v${version} archive"
  exit 66
fi

mkdir -p "${output_path:h}"
/usr/bin/install -m 0755 "$binary_path" "$output_path"
installed_sha256="$(/usr/bin/shasum -a 256 "$output_path" | /usr/bin/awk '{print $1}')"
if [[ "$installed_sha256" != "$binary_sha256" ]]; then
  print -u2 "extracted CUA Driver binary checksum mismatch"
  exit 78
fi
print "$output_path"

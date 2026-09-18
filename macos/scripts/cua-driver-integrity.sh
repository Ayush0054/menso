#!/bin/zsh
set -euo pipefail

# Called before helper signing and again after its final signature, before the
# outer app is signed. Only the bundle copy of the manifest is modified.
if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 verify-input|record-signed /absolute/path/to/Menso.app"
  exit 64
fi
operation="$1"
app_path="$2"
driver="$app_path/Contents/Helpers/cua-driver"
manifest="$app_path/Contents/Resources/CuaDriver/manifest.json"
policy="$app_path/Contents/Resources/CuaDriver/session-policy.yaml"
reviewed_binary="3ee06efc14bb4ec501a4a8d8963514150684332f0281cc224c51b3dba3ef76ea"
reviewed_policy="4e1371fef7b210147782feffdb6c31ee2707884d1d5484d39cde861230d00707"

case "$operation" in
  verify-input)
    [[ "$(/usr/bin/shasum -a 256 "$driver" | /usr/bin/awk '{print $1}')" == "$reviewed_binary" && \
       "$(/usr/bin/plutil -extract binary_sha256 raw -o - "$manifest")" == "$reviewed_binary" && \
       "$(/usr/bin/shasum -a 256 "$policy" | /usr/bin/awk '{print $1}')" == "$reviewed_policy" && \
       "$(/usr/bin/plutil -extract session_policy_sha256 raw -o - "$manifest")" == "$reviewed_policy" ]] \
      || { print -u2 "CUA inputs do not match the reviewed release; refusing to sign"; exit 65; }
    ;;
  record-signed)
    /usr/bin/codesign --verify --strict "$driver"
    signed_digest="$(/usr/bin/shasum -a 256 "$driver" | /usr/bin/awk '{print $1}')"
    /usr/bin/plutil -insert packaged_binary_sha256 -string "$signed_digest" "$manifest"
    ;;
  *) print -u2 "unknown CUA integrity operation"; exit 64 ;;
esac

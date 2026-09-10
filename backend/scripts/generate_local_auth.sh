#!/bin/zsh
set -euo pipefail

# Generates local-only AgentOS authentication material. Nothing in this
# directory is committed, loaded by the model, or sent to the backend except
# the public JWKS. The private key is used only here to mint a short-lived JWT.

backend_root="${0:A:h:h}"
auth_directory="$backend_root/.local-auth"
private_key="$auth_directory/private.pem"
public_key="$auth_directory/public.pem"
jwks_file="$auth_directory/jwks.json"
token_file="$auth_directory/menso-local.jwt"
client_env="$auth_directory/client.env"
runtime_env="$auth_directory/runtime.env"
expiry_file="$auth_directory/token-expiry.txt"

lifetime_hours="${1:-24}"
subject="${2:-menso-local-user}"

if [[ ! "$lifetime_hours" =~ ^[0-9]+$ ]] \
  || (( lifetime_hours < 1 || lifetime_hours > 168 )); then
  print -u2 "usage: $0 [lifetime-hours: 1-168] [subject]"
  exit 64
fi
if [[ ! "$subject" =~ ^[A-Za-z0-9._:@-]{1,128}$ ]]; then
  print -u2 "subject must contain only A-Z, a-z, 0-9, dot, underscore, colon, at, or hyphen"
  exit 64
fi

umask 077
mkdir -p "$auth_directory"

if [[ ! -f "$private_key" ]]; then
  /opt/homebrew/bin/openssl genpkey \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:3072 \
    -out "$private_key" >/dev/null 2>&1
fi
/opt/homebrew/bin/openssl pkey \
  -in "$private_key" \
  -pubout \
  -out "$public_key" >/dev/null 2>&1

base64url() {
  /opt/homebrew/bin/openssl base64 -A | tr '+/' '-_' | tr -d '='
}

key_id="$(
  /opt/homebrew/bin/openssl pkey -pubin -in "$public_key" -outform DER \
    | /opt/homebrew/bin/openssl dgst -sha256 \
    | /usr/bin/awk '{print substr($NF, 1, 16)}'
)"
modulus_hex="$(
  /opt/homebrew/bin/openssl rsa -pubin -in "$public_key" -modulus -noout \
    | /usr/bin/cut -d= -f2
)"
modulus="$(print -rn -- "$modulus_hex" | /usr/bin/xxd -r -p | base64url)"

temporary_jwks="$auth_directory/jwks.json.tmp"
print -r -- "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"$key_id\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"$modulus\",\"e\":\"AQAB\"}]}" \
  > "$temporary_jwks"
mv "$temporary_jwks" "$jwks_file"

issued_at="$(/bin/date +%s)"
expires_at="$(( issued_at + lifetime_hours * 3600 ))"
expires_at_iso="$(/bin/date -u -r "$expires_at" '+%Y-%m-%dT%H:%M:%SZ')"
header="{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"$key_id\"}"
payload="{\"sub\":\"$subject\",\"aud\":\"menso-os\",\"iat\":$issued_at,\"nbf\":$issued_at,\"exp\":$expires_at,\"scopes\":[\"agents:menso:run\",\"sessions:read\",\"learnings:read\",\"learnings:write\",\"realtime:connect\"]}"
encoded_header="$(print -rn -- "$header" | base64url)"
encoded_payload="$(print -rn -- "$payload" | base64url)"
signing_input="$encoded_header.$encoded_payload"
signature="$(
  print -rn -- "$signing_input" \
    | /opt/homebrew/bin/openssl dgst -sha256 -sign "$private_key" \
    | base64url
)"
token="$signing_input.$signature"

print -r -- "$token" > "$token_file"
print -r -- "$expires_at_iso" > "$expiry_file"
{
  print -r -- "MENSO_TEST_TOKEN=$token"
  print -r -- "MENSO_TEST_TOKEN_EXPIRES_AT=$expires_at_iso"
} > "$client_env"
{
  print -r -- "JWT_ALGORITHM=RS256"
  print -r -- "JWT_JWKS_FILE=.local-auth/jwks.json"
} > "$runtime_env"

chmod 600 "$private_key" "$public_key" "$jwks_file" \
  "$token_file" "$expiry_file" "$client_env" "$runtime_env"

print "Created ignored local auth material in $auth_directory"
print "Bearer token: $token_file"
print "Token expiry: $expires_at_iso"

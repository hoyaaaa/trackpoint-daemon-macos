#!/bin/bash
# Create once in the login keychain; never replace an existing certificate/key.
set -euo pipefail
umask 077
name='TrackPointD Local Code Signing'
work=$(mktemp -d "${TMPDIR:-/tmp}/trackpointd-signing.XXXXXX")
lock=""
trap 'rm -rf -- "$work"; [ -z "$lock" ] || rmdir "$lock"' EXIT
keychain=$(security login-keychain | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
[ -n "$keychain" ] || { echo 'No login keychain found.' >&2; exit 1; }
# Fail safely on concurrent installs; do not race into creating two identities.
mkdir "$keychain.trackpointd-lock" || { echo 'Another signing setup is running.' >&2; exit 1; }
lock="$keychain.trackpointd-lock"
if security find-certificate -c "$name" -p "$keychain" > "$work/cert.pem" 2>/dev/null; then
    :
else
    status=$?
    [ "$status" -eq 44 ] || { echo 'Cannot read the login keychain; unlock it and retry.' >&2; exit "$status"; }
    # Some security versions leave empty output on a miss. No persistent key export.
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$name" -keyout "$work/key.pem" -out "$work/cert.pem" \
        -extensions signing \
        -config <(printf '[req]\ndistinguished_name=dn\n[dn]\n[signing]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:false\n') >&2
    openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/identity.p12" -passout pass: \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >&2
    security import "$work/identity.p12" -k "$keychain" -P '' -T /usr/bin/codesign >&2
fi
identity=$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || { echo 'Invalid local certificate.' >&2; exit 1; }
# Test actual private-key access: find-identity -v excludes untrusted self-signed keys.
cp /usr/bin/true "$work/probe"
codesign --force --sign "$identity" "$work/probe" >&2
codesign --verify --strict "$work/probe" >&2
printf '%s\n' "$identity"

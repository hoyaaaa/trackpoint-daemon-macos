#!/bin/bash
# Print an explicitly chosen identity, or the pinned non-secret local certificate hash.
# A configured but unusable identity must fail signing, never silently become ad-hoc.
trackpointd_signing_identity() {
    if [ "${TRACKPOINTD_SIGN_IDENTITY+x}" = x ]; then
        [ -n "$TRACKPOINTD_SIGN_IDENTITY" ] || { echo 'TRACKPOINTD_SIGN_IDENTITY is empty.' >&2; return 2; }
        printf '%s\n' "$TRACKPOINTD_SIGN_IDENTITY"
        return 0
    fi
    local config="${TRACKPOINTD_SIGNING_CONFIG:-${HOME:?}/.config/trackpointd/signing-identity}"
    if [ -e "$config" ] || [ -L "$config" ]; then
        local identity
        identity=$(cat -- "$config") || return 2
        [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || { echo "Invalid certificate fingerprint in $config" >&2; return 2; }
        printf '%s\n' "$identity"
        return 0
    fi
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-signing.sh"
}

#!/bin/bash
# Shared local identity; absence is an error rather than silently changing back to ad-hoc signing.
captions_signing_directory="$HOME/Library/Application Support/CodexCaptions/Signing"
if [[ -n "${CAPTIONS_SIGNING_IDENTITY:-}" ]]; then
    captions_signing_identity="$CAPTIONS_SIGNING_IDENTITY"
    captions_signing_arguments=(--sign "$captions_signing_identity" --timestamp=none)
    if [[ -n "${CAPTIONS_SIGNING_KEYCHAIN:-}" ]]; then
        captions_signing_arguments+=(--keychain "$CAPTIONS_SIGNING_KEYCHAIN")
    fi
else
    if [[ ! -f "$captions_signing_directory/identity.json" ]]; then
        echo 'Stable signing identity is missing. Run: python3 scripts/setup_signing.py' >&2
        exit 1
    fi
    captions_signing_identity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"])' "$captions_signing_directory/identity.json")
    captions_signing_keychain=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keychain"])' "$captions_signing_directory/identity.json")
    captions_signing_password=$(cat "$captions_signing_directory/keychain-password")
    security unlock-keychain -p "$captions_signing_password" "$captions_signing_keychain"
    unset captions_signing_password
    captions_signing_arguments=(--sign "$captions_signing_identity" --keychain "$captions_signing_keychain" --timestamp=none)
fi
if [[ "$captions_signing_identity" == '-' ]]; then
    echo 'Ad-hoc signing changes application identity between builds. Select a persistent certificate.' >&2
    exit 1
fi

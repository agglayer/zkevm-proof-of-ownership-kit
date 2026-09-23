#!/bin/bash
# Signs the fixed ownership-proof message (message-template.txt) via standard
# personal_sign (EIP-191), and appends the result to a case's signatures.json.
#
# The key never touches this script: signing is delegated to `cast wallet sign` with a
# signer flag of your choice — a hardware wallet (--ledger / --trezor), a Foundry
# keystore (--account <name> / --keystore <path>), or a hidden prompt (--interactive).
# Raw-key flags (--private-key, --mnemonic, ...) are rejected, since anything on the
# command line lands in your shell history and is visible to other processes.
#
# Required env vars:
#   ADDRESS   the address being proven (must match the key the signer flag resolves to;
#             the signature is verified against it before anything is written).
#   NONCE     the shared nonce for this submission. Reuse the exact same value for
#             every signature in the same case, so Polygon can match them together.
#
# Usage:
#   ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh <signatures.json|-> <signer flags...>
#   ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh --print-message
#
# Examples:
#   ... sign-message.sh cases/<case-id>/signatures.json --ledger
#   ... sign-message.sh cases/<case-id>/signatures.json --account my-keystore
#   ... sign-message.sh cases/<case-id>/signatures.json --interactive
#
# With a signatures.json path, the {address, message, signature} entry is appended to it
# (the file is created with an empty array if it doesn't exist yet). With `-`, the entry
# is printed to stdout instead. --print-message only prints the exact message to sign,
# for signing outside this kit (e.g. https://etherscan.io/verifiedSignatures).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: ADDRESS=0x... NONCE=<nonce> $0 <signatures.json|-> <signer flags...>" >&2
    echo "       ADDRESS=0x... NONCE=<nonce> $0 --print-message" >&2
    echo "Signer flags: --ledger | --trezor | --account <name> | --keystore <path> | --interactive" >&2
}

for bin in cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "cast" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

if [ -z "${ADDRESS:-}" ]; then
    echo "Error: ADDRESS env var is required." >&2
    exit 1
fi
if [ -z "${NONCE:-}" ]; then
    echo "Error: NONCE env var is required — reuse the same nonce for every signature in this case." >&2
    exit 1
fi
if ! [[ "${ADDRESS}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Error: ADDRESS '${ADDRESS}' is not a 20-byte hex address." >&2
    exit 1
fi

address="$(cast to-check-sum-address "${ADDRESS}")"
date_str="$(date -u +%Y-%m-%d)"

template="$(cat "${script_dir}/message-template.txt")"
message="${template//<address>/${address}}"
message="${message//<nonce>/${NONCE}}"
message="${message//<date>/${date_str}}"

if [ "${1:-}" = "--print-message" ]; then
    printf '%s\n' "${message}"
    exit 0
fi

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi
out_path="$1"
shift

for arg in "$@"; do
    case "${arg}" in
    --private-key* | --mnemonic*)
        echo "Error: '${arg%%=*}' is not allowed — use --ledger, --trezor, --account, --keystore or --interactive." >&2
        exit 1
        ;;
    esac
done

signature="$(cast wallet sign "$@" "${message}")"

if ! cast wallet verify --address "${address}" "${message}" "${signature}" >/dev/null 2>&1; then
    echo "Error: the signature was not produced by ${address} — check the signer flag / derivation path." >&2
    exit 1
fi

entry="$(jq -n --arg address "${address}" --arg message "${message}" --arg signature "${signature}" \
    '{address: $address, message: $message, signature: $signature}')"

if [ "${out_path}" = "-" ]; then
    echo "${entry}"
    exit 0
fi

if [ -f "${out_path}" ]; then
    existing="$(jq --arg addr "${address}" \
        '[.[] | select(.address | ascii_downcase == ($addr | ascii_downcase))] | length' \
        "${out_path}")"
    if [ "${existing}" != "0" ]; then
        echo "Error: ${address} already has a signature in ${out_path}." >&2
        exit 1
    fi
    updated="$(jq --argjson entry "${entry}" '. + [$entry]' "${out_path}")"
else
    updated="$(jq -n --argjson entry "${entry}" '[$entry]')"
fi

echo "${updated}" >"${out_path}"
echo "Signature for ${address} appended to ${out_path}"

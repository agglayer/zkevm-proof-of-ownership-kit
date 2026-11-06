#!/bin/bash
# Signs the fixed ownership-proof message (message-template.txt) via standard
# personal_sign (EIP-191), and appends the result to a case's signatures.json.
#
# The message is bound to your case: it carries the locked contract and the destination (read
# from the case's recovery.json) and the "case hash" of recovery.json + move.sh
# (ownership-proof/case-hash.sh). So a signature only counts for those exact files: if
# recovery.json or move.sh change afterwards — even a space — every signature must be made
# again. Sign LAST, once both files are final, and read move.sh first: you are signing it.
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
# Optional:
#   CASE_DIR  the case directory (cases/<case-id>). Default: the directory of the
#             signatures.json given. Required with `-` and with --print-message.
#
# Usage:
#   ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh <signatures.json|-> <signer flags...>
#   CASE_DIR=cases/<case-id> ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh --print-message
#
# Examples:
#   ... sign-message.sh cases/<case-id>/signatures.json --ledger
#   ... sign-message.sh cases/<case-id>/signatures.json --account my-keystore
#   ... sign-message.sh cases/<case-id>/signatures.json --interactive
#
# With a signatures.json path, the {address, message, signature} entry is appended to it
# (the file is created with an empty array if it doesn't exist yet). With `-`, the entry
# is printed to stdout instead. --print-message only prints the exact message to sign,
# for signing outside this kit (e.g. https://etherscan.io/verifiedSignatures): check the
# contract and destination in it before signing it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: ADDRESS=0x... NONCE=<nonce> $0 <signatures.json|-> <signer flags...>" >&2
    echo "       CASE_DIR=cases/<case-id> ADDRESS=0x... NONCE=<nonce> $0 --print-message" >&2
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

print_only=0
out_path=""
if [ "${1:-}" = "--print-message" ]; then
    print_only=1
else
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
fi

# The case the message is bound to.
if [ -n "${CASE_DIR:-}" ]; then
    case_dir="${CASE_DIR%/}"
elif [ "${print_only}" -eq 0 ] && [ "${out_path}" != "-" ]; then
    case_dir="$(dirname "${out_path}")"
else
    echo "Error: CASE_DIR=cases/<case-id> is required with --print-message and with '-' (the message is bound to that case's recovery.json and move.sh)." >&2
    exit 1
fi
[ -f "${case_dir}/recovery.json" ] || { echo "Error: ${case_dir}/recovery.json not found — is ${case_dir} the case directory?" >&2; exit 1; }
case_hash="$("${script_dir}/case-hash.sh" "${case_dir}")"
locked_contract="$(jq -r '.locked_contract // empty' "${case_dir}/recovery.json")"
destination="$(jq -r '.destination // empty' "${case_dir}/recovery.json")"
for v in "${locked_contract}" "${destination}"; do
    if ! [[ "${v}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "Error: ${case_dir}/recovery.json needs a valid locked_contract and destination before signing (check it with recovery-tx/validate-recovery.sh)." >&2
        exit 1
    fi
done
locked_contract="$(cast to-check-sum-address "${locked_contract}")"
destination="$(cast to-check-sum-address "${destination}")"

address="$(cast to-check-sum-address "${ADDRESS}")"
date_str="$(date -u +%Y-%m-%d)"

template="$(cat "${script_dir}/message-template.txt")"
message="${template//<address>/${address}}"
message="${message//<locked_contract>/${locked_contract}}"
message="${message//<destination>/${destination}}"
message="${message//<case_hash>/${case_hash}}"
message="${message//<nonce>/${NONCE}}"
message="${message//<date>/${date_str}}"

if [ "${print_only}" -eq 1 ]; then
    printf '%s\n' "${message}"
    exit 0
fi

# Signatures made for another version of the files cannot be mixed with this one.
if [ "${out_path}" != "-" ] && [ -f "${out_path}" ]; then
    first_message="$(jq -r '.[0].message // empty' "${out_path}")"
    hash_re='case hash: ([0-9a-f]{64})'
    if [[ "${first_message}" =~ ${hash_re} ]] && [ "${BASH_REMATCH[1]}" != "${case_hash}" ]; then
        echo "Error: ${out_path} already holds signatures for a different version of recovery.json/move.sh (case hash ${BASH_REMATCH[1]}, now ${case_hash})." >&2
        echo "A change to either file invalidates the signatures: empty signatures.json (echo '[]' > ${out_path}) and sign again with every address." >&2
        exit 1
    fi
fi

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

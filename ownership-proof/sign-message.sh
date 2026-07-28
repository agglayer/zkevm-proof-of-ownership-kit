#!/bin/bash
# Signs the fixed ownership-proof message (message-template.txt) with a real private
# key, via standard personal_sign (EIP-191), and appends the result to a case's
# signatures.json.
#
# Required env vars:
#   PRIVATE_KEY   the real private key of the address being proven. Never pass this as
#                 a CLI argument (it would land in your shell history) — env var only.
#   NONCE         the shared nonce for this submission. Reuse the exact same value for
#                 every signature in the same case, so Polygon can match them together.
#
# Usage:
#   PRIVATE_KEY=0x... NONCE=<your-case-nonce> ./ownership-proof/sign-message.sh [path/to/signatures.json]
#
# With a signatures.json path given, the {address, message, signature} entry is
# appended to it (the file is created with an empty array if it doesn't exist yet).
# Without a path, the entry is printed to stdout instead.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for bin in cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "cast" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

if [ -z "${PRIVATE_KEY:-}" ]; then
    echo "Error: PRIVATE_KEY env var is required." >&2
    exit 1
fi
if [ -z "${NONCE:-}" ]; then
    echo "Error: NONCE env var is required — reuse the same nonce for every signature in this case." >&2
    exit 1
fi

address="$(cast wallet address --private-key "${PRIVATE_KEY}")"
date_str="$(date -u +%Y-%m-%d)"

template="$(cat "${script_dir}/message-template.txt")"
message="${template//<address>/${address}}"
message="${message//<nonce>/${NONCE}}"
message="${message//<date>/${date_str}}"

signature="$(cast wallet sign --private-key "${PRIVATE_KEY}" "${message}")"

entry="$(jq -n --arg address "${address}" --arg message "${message}" --arg signature "${signature}" \
    '{address: $address, message: $message, signature: $signature}')"

out_path="${1:-}"
if [ -z "${out_path}" ]; then
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

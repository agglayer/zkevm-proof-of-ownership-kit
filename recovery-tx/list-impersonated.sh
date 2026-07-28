#!/bin/bash
# Prints the distinct addresses that sent one or more transactions on the shadow-fork —
# i.e., the addresses that had to be impersonated to execute the recovery — by reading
# each transaction's mined receipt (its `from` field). Impersonation itself isn't
# tracked as queryable state by Anvil, but a mined tx's `from` field always tells you
# who sent it, which is what actually matters here.
#
# With --signatures <path>, also cross-checks that every address found already has a
# signature in that case's signatures.json, and fails loudly listing whichever is
# missing — run this before filling out submission/SUBMIT.md.
#
# Usage:
#   recovery-tx/list-impersonated.sh <tx-hash> [<tx-hash> ...]
#   recovery-tx/list-impersonated.sh --signatures cases/<case-id>/signatures.json <tx-hash> [<tx-hash> ...]
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

for bin in cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "cast" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

signatures_path=""
if [ "${1:-}" = "--signatures" ]; then
    signatures_path="${2:?--signatures requires a path}"
    shift 2
fi

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 [--signatures <path>] <tx-hash> [<tx-hash> ...]" >&2
    exit 1
fi

addresses=()
for tx_hash in "$@"; do
    from="$(cast receipt "${tx_hash}" --json --rpc-url "${RPC_URL}" | jq -r '.from')"
    if [ -z "${from}" ] || [ "${from}" = "null" ]; then
        echo "Error: could not read a 'from' address from the receipt for ${tx_hash}." >&2
        exit 1
    fi
    echo "${tx_hash} -> ${from}"
    addresses+=("${from}")
done

unique="$(printf '%s\n' "${addresses[@]}" | sort -u -f)"

echo
echo "Distinct impersonated addresses:"
echo "${unique}"

if [ -z "${signatures_path}" ]; then
    exit 0
fi

echo
echo "Cross-checking against ${signatures_path} ..."
if [ ! -f "${signatures_path}" ]; then
    echo "Error: ${signatures_path} not found." >&2
    exit 1
fi

missing=0
while IFS= read -r addr; do
    [ -z "${addr}" ] && continue
    found="$(jq --arg addr "${addr}" \
        '[.[] | select(.address | ascii_downcase == ($addr | ascii_downcase))] | length' \
        "${signatures_path}")"
    if [ "${found}" = "0" ]; then
        echo "MISSING signature for ${addr}" >&2
        missing=1
    fi
done <<<"${unique}"

if [ "${missing}" -eq 0 ]; then
    echo "All impersonated addresses have a signature in ${signatures_path}."
    echo "(Remember: the destination EOA also needs a signature — this check only covers senders.)"
else
    echo >&2
    echo "Error: one or more impersonated addresses are missing a signature — run" >&2
    echo "ownership-proof/sign-message.sh for each before submitting." >&2
    exit 1
fi

#!/bin/bash
# Prints the distinct addresses that sent one or more transactions on the shadow-fork —
# i.e., the addresses that had to be impersonated to execute the recovery — by reading
# each transaction's mined receipt (its `from` field). Impersonation itself isn't
# tracked as queryable state by Anvil, but a mined tx's `from` field always tells you
# who sent it, which is what actually matters here.
#
# With --signatures <path>, also verifies that case's signatures.json with
# ownership-proof/verify-signature.sh and cross-checks that every EOA sender has an
# entry, failing loudly listing whichever is invalid or missing — run this before
# filling out submission/SUBMIT.md. Contract senders can't sign, so they are listed
# separately instead.
#
# Usage:
#   recovery-tx/list-impersonated.sh <tx-hash> [<tx-hash> ...]
#   recovery-tx/list-impersonated.sh --signatures cases/<case-id>/signatures.json <tx-hash> [<tx-hash> ...]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
echo "Verifying ${signatures_path} ..."
invalid=0
"${script_dir}/../ownership-proof/verify-signature.sh" "${signatures_path}" || invalid=1

echo
echo "Cross-checking senders against ${signatures_path} ..."

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

signed="$(jq -r '.[]?.address? // empty' "${signatures_path}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"

missing=0
contracts=""
while IFS= read -r addr; do
    [ -z "${addr}" ] && continue
    code="$(cast code "${addr}" --rpc-url "${RPC_URL}")"
    if [ "${code}" != "0x" ]; then
        contracts+="${addr}"$'\n'
        continue
    fi
    if ! grep -Fxq "$(lower "${addr}")" <<<"${signed}"; then
        echo "MISSING signature for ${addr}" >&2
        missing=1
    fi
done <<<"${unique}"

if [ -n "${contracts}" ]; then
    echo
    echo "NOTE: these senders are contracts, which have no private key and cannot sign:"
    printf '%s' "${contracts}"
    echo "Ownership of a contract is proven by signatures from the EOA(s) that control it"
    echo "on-chain (owner, multisig signers, admin). Add those signatures to"
    echo "${signatures_path} and explain the control path in your submission — see"
    echo "submission/SUBMIT.md."
fi

if [ "${invalid}" -ne 0 ] || [ "${missing}" -ne 0 ]; then
    echo >&2
    echo "Error: fix the invalid/missing signatures above — run" >&2
    echo "ownership-proof/sign-message.sh for each EOA before submitting." >&2
    exit 1
fi

echo
echo "Every entry in ${signatures_path} is a valid signature, and every EOA sender is covered."
echo "(Remember: the destination EOA also needs a signature — this check only covers senders.)"

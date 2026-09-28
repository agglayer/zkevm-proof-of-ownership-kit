#!/bin/bash
# Verifies every entry of a case's signatures.json — the check Polygon runs on a
# submission, and that stakeholders can run themselves before submitting. An entry
# passes only if:
#   - `address` is a 20-byte hex address and `signature` a 65-byte hex signature,
#   - `message` is exactly message-template.txt filled in with that same address,
#   - the signature recovers to that address (EIP-191 personal_sign, via cast).
# Across the file, every entry must use the same nonce and no address may repeat.
#
# Requires: cast (Foundry toolchain, https://getfoundry.sh), jq. No RPC needed.
#
# Usage: ownership-proof/verify-signature.sh cases/<case-id>/signatures.json
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
signatures_path="${1:?Usage: ownership-proof/verify-signature.sh <path/to/signatures.json>}"

for bin in cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "cast" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

if [ ! -f "${signatures_path}" ]; then
    echo "Error: ${signatures_path} not found." >&2
    exit 1
fi
if ! jq -e 'type == "array" and length > 0' "${signatures_path}" >/dev/null 2>&1; then
    echo "Error: ${signatures_path} must be a non-empty JSON array." >&2
    exit 1
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Turn the template into an anchored regex. Placeholders appear in the order
# <address>, <nonce>, <date>, which fixes the capture-group numbering below.
template="$(cat "${script_dir}/message-template.txt")"
message_re="$(printf '%s' "${template}" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
address_re='(0x[0-9a-fA-F]{40})'
nonce_re='(.+)'
date_re='([0-9]{4}-[0-9]{2}-[0-9]{2})'
message_re="${message_re//<address>/${address_re}}"
message_re="${message_re//<nonce>/${nonce_re}}"
message_re="${message_re//<date>/${date_re}}"
message_re="^${message_re}$"

failed=0
seen=""
nonces=""
index=0
while IFS= read -r entry; do
    index=$((index + 1))
    e_addr="$(jq -r '.address // ""' <<<"${entry}")"
    e_msg="$(jq -r '.message // ""' <<<"${entry}")"
    e_sig="$(jq -r '.signature // ""' <<<"${entry}")"
    label="#${index} ${e_addr:-<no address>}"

    if ! [[ "${e_addr}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "FAIL ${label}: address is not a 20-byte hex address." >&2
        failed=1
        continue
    fi
    if ! [[ "${e_sig}" =~ ^0x[0-9a-fA-F]{130}$ ]]; then
        echo "FAIL ${label}: signature is not a 65-byte hex signature." >&2
        failed=1
        continue
    fi
    if ! [[ "${e_msg}" =~ ${message_re} ]]; then
        echo "FAIL ${label}: message does not match ownership-proof/message-template.txt." >&2
        failed=1
        continue
    fi
    m_addr="${BASH_REMATCH[1]}"
    m_nonce="${BASH_REMATCH[2]}"
    m_date="${BASH_REMATCH[3]}"
    if [ "$(lower "${m_addr}")" != "$(lower "${e_addr}")" ]; then
        echo "FAIL ${label}: message is for ${m_addr}, not for the entry's address." >&2
        failed=1
        continue
    fi
    if ! cast wallet verify --address "${e_addr}" "${e_msg}" "${e_sig}" >/dev/null 2>&1; then
        echo "FAIL ${label}: signature does not recover to that address." >&2
        failed=1
        continue
    fi
    if grep -Fxq "$(lower "${e_addr}")" <<<"${seen}"; then
        echo "FAIL ${label}: duplicate entry for this address." >&2
        failed=1
        continue
    fi

    seen+="$(lower "${e_addr}")"$'\n'
    nonces+="${m_nonce}"$'\n'
    echo "OK   ${label} (nonce: ${m_nonce}, date: ${m_date})"
done < <(jq -c '.[]' "${signatures_path}")

distinct_nonces="$(printf '%s' "${nonces}" | sort -u)"
if [ "$(printf '%s' "${distinct_nonces}" | grep -c '')" -gt 1 ]; then
    echo "FAIL: entries use different nonces — every signature in a case must share one:" >&2
    printf '%s\n' "${distinct_nonces}" >&2
    failed=1
fi

echo
if [ "${failed}" -ne 0 ]; then
    echo "Error: ${signatures_path} has invalid entries — see FAIL lines above." >&2
    exit 1
fi
echo "All ${index} signatures in ${signatures_path} are valid (nonce: ${distinct_nonces})."

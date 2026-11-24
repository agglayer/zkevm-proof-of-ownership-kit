#!/bin/bash
# Builds a case's recovery.json from the transactions move.sh mined on the shadow-fork: one
# output per BridgeEvent that the zkEVM bridge emitted in them, in order. Each output is a
# bridge exit Polygon recovers through the certificate, with the BridgeEvent's fields, named as
# aggkit's bridgesync names them (the origin pair grouped as token_info, as in a certificate's
# bridge exit):
#   leaf_type            0 bridgeAsset, 1 bridgeMessage
#   token_info           {origin_network, origin_token_address}: the token (bridgeAsset; ETH is
#                        0 / 0x0...0) or the sender of the message (bridgeMessage)
#   destination_network, destination_address  where it goes; a bridgeAsset must go to network 0
#
# A bridgeAsset of a token native to this chain (origin_network = the bridge's networkID(), 1 on
# zkEVM) is refused: a recovery only bridges ETH and wrapped tokens.
#   amount               base units, as a string (ETH carried, for a bridgeMessage)
#   metadata             hex, as emitted (not decoded)
#   deposit_count        the bridge's deposit counter
#
# The result goes to stdout ({"version": 1, "outputs": [...]}); messages go to stderr.
# submission/helpers/generate.sh runs this script on a fresh fork.
#
# Requires: cast, jq.
#
# Usage:
#   recovery-tx/build-recovery.sh <tx-hash> [<tx-hash> ...] > cases/<case-id>/recovery.json
#
# Env overrides:
#   RPC_URL         the fork (default http://127.0.0.1:8545)
#   BRIDGE_ADDRESS  TESTING ONLY: the bridge contract (default: the zkEVM bridge,
#                   0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe)
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
BRIDGE_ADDRESS="${BRIDGE_ADDRESS:-0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe}"
# keccak256("BridgeEvent(uint8,uint32,address,uint32,address,uint256,bytes,uint32)")
bridge_topic="0x501781209a1f8899323b96b4ef08b168df93e0a90c673d1e4cce39366cb62f9b"

for bin in cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "cast" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <tx-hash> [<tx-hash> ...]" >&2
    exit 1
fi

die() {
    echo "Error: $*" >&2
    exit 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[[ "${BRIDGE_ADDRESS}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "BRIDGE_ADDRESS '${BRIDGE_ADDRESS}' is not an address."
bridge="$(lower "${BRIDGE_ADDRESS}")"
network_id=""

# One JSON object per line; slurped at the end (no growing JSON on a command line).
outputs=""
for tx in "$@"; do
    [[ "${tx}" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "'${tx}' is not a transaction hash."
    receipt="$(cast receipt "${tx}" --json --rpc-url "${RPC_URL}")" || die "could not read the receipt of ${tx} from ${RPC_URL}."
    receipt_data="$(jq -r --arg bridge "${bridge}" --arg topic "${bridge_topic}" \
        '.logs[] | select((.address | ascii_downcase) == $bridge and ((.topics[0] // "") | ascii_downcase) == $topic) | .data | ascii_downcase' <<<"${receipt}")"
    [ -n "${receipt_data}" ] || continue

    while IFS= read -r data; do
        [[ "${data}" =~ ^0x([0-9a-f]{64})+$ ]] || die "unexpected BridgeEvent data in ${tx}: ${data}"
        decoded="$(cast decode-abi --input "f(uint8,uint32,address,uint32,address,uint256,bytes,uint32)" "${data}")" \
            || die "could not decode a BridgeEvent of ${tx}."
        fields=""
        while IFS= read -r line; do fields+="${line%% *}"$'\n'; done <<<"${decoded}"
        leaf_type="$(sed -n 1p <<<"${fields}")"
        origin_network="$(sed -n 2p <<<"${fields}")"
        origin_address="$(sed -n 3p <<<"${fields}")"
        destination_network="$(sed -n 4p <<<"${fields}")"
        destination_address="$(sed -n 5p <<<"${fields}")"
        amount="$(sed -n 6p <<<"${fields}")"
        metadata="$(sed -n 7p <<<"${fields}")"
        deposit_count="$(sed -n 8p <<<"${fields}")"
        for v in "${leaf_type}" "${origin_network}" "${destination_network}" "${amount}" "${deposit_count}"; do
            [[ "${v}" =~ ^[0-9]+$ ]] || die "unexpected value in a BridgeEvent of ${tx}: ${v}"
        done
        for v in "${origin_address}" "${destination_address}"; do
            [[ "${v}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "unexpected address in a BridgeEvent of ${tx}: ${v}"
        done
        [[ "${metadata}" =~ ^0x([0-9a-fA-F]{2})*$ ]] || die "unexpected metadata in a BridgeEvent of ${tx}: ${metadata}"
        case "${leaf_type}" in
        0)
            [ "${destination_network}" = "0" ] \
                || die "${tx} calls bridgeAsset to network ${destination_network}; a recovery can only bridge assets to Ethereum (destinationNetwork 0)."
            if [ -z "${network_id}" ]; then
                network_id="$(cast call "${BRIDGE_ADDRESS}" "networkID()(uint32)" --rpc-url "${RPC_URL}")" \
                    || die "could not read networkID() from the bridge (${BRIDGE_ADDRESS})."
                [[ "${network_id}" =~ ^[0-9]+$ ]] || die "unexpected networkID() from the bridge: ${network_id}"
            fi
            [ "${origin_network}" != "${network_id}" ] \
                || die "${tx} bridges ${origin_address}, a token native to this chain (origin network ${network_id}); a recovery cannot bridge native L2 tokens."
            echo "bridgeAsset   ${tx}: ${amount} of token (network ${origin_network}, ${origin_address}) to ${destination_address} on network 0" >&2
            ;;
        1)
            echo "bridgeMessage ${tx}: from ${origin_address} to ${destination_address} on network ${destination_network} (${amount} wei)" >&2
            ;;
        *)
            die "${tx} emits a BridgeEvent with an unknown leaf type ${leaf_type}."
            ;;
        esac
        output="$(jq -n -c --argjson lt "${leaf_type}" \
            --argjson on "${origin_network}" --arg oa "$(cast to-check-sum-address "${origin_address}")" \
            --argjson dn "${destination_network}" --arg da "$(cast to-check-sum-address "${destination_address}")" \
            --arg amount "${amount}" --arg md "${metadata}" --argjson dc "${deposit_count}" \
            '{leaf_type: $lt, token_info: {origin_network: $on, origin_token_address: $oa}, destination_network: $dn,
              destination_address: $da, amount: $amount, metadata: $md, deposit_count: $dc}')"
        outputs+="${output}"$'\n'
    done <<<"${receipt_data}"
done

[ -n "${outputs}" ] \
    || die "none of these transactions calls the bridge (${BRIDGE_ADDRESS}): move.sh must end with a call to bridgeAsset / bridgeMessage."

printf '%s' "${outputs}" | jq -s '{version: 1, outputs: .}'

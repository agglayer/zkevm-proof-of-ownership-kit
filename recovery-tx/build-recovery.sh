#!/bin/bash
# Builds a case's recovery.json from the transactions move.sh mined on the shadow-fork: one
# output per BridgeEvent that the zkEVM bridge emitted in them, in order. Each output is a
# bridge exit Polygon recovers through the certificate, with the BridgeEvent's fields, named as
# aggkit's bridgesync names them (the origin pair grouped as token_info and leaf_type labeled, as
# in a certificate's bridge exit; the deposit count is left out):
#   leaf_type            "Transfer" (bridgeAsset) or "Message" (bridgeMessage)
#   token_info           {origin_network, origin_token_address}: the token (bridgeAsset; ETH is
#                        0 / 0x0...0) or the sender of the message (bridgeMessage)
#   destination_network, destination_address  where it goes; a bridgeAsset must go to network 0
#   amount               base units, as a string (ETH carried, for a bridgeMessage)
#   metadata             hex, as emitted (not decoded)
#
# A bridgeAsset of a token native to this chain (origin_network = the bridge's networkID(), 1 on
# zkEVM) is refused: a recovery only bridges ETH and wrapped tokens.
#
# A second section, origin_SC_funds, lists the contracts that held the funds before move.sh: for
# each (in the order of the outputs it paid for), the tokens it bridged out (token_info; ETH is
# 0 / 0x0...0, also when a bridgeMessage carries it) and the total amount of each. Outputs of
# amount "0" pay for nothing.
#
# Each output's contract is found by balance diff over all the transactions: per asset (ETH, from
# the value of every call in the call traces; a wrapped token, from its Transfer logs), the
# candidates are the contracts (code at the block before move.sh, not the bridge) whose balance
# of it went down. One candidate: it paid for every output of that asset. Several: each bridge
# call is followed up its own call chain (the bridge's caller, then that frame's caller...) to the
# first candidate. The outputs credited to a contract may not total more than it lost. No
# candidate, or a call chain that reaches none, is refused.
#
# The result goes to stdout ({"version": 1, "outputs": [...], "origin_SC_funds": [...]});
# messages go to stderr.
# submission/helpers/generate.sh runs this script on a fresh fork.
#
# Requires: cast, jq, bc, and an RPC that serves debug_traceTransaction (the shadow-fork does).
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
# keccak256("Transfer(address,address,uint256)")
transfer_topic="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
eth_asset="eth"

for bin in cast jq bc; do
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
# bc without line wrapping (amounts are 256-bit).
bc_run() { BC_LINE_LENGTH=0 bc; }

[[ "${BRIDGE_ADDRESS}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "BRIDGE_ADDRESS '${BRIDGE_ADDRESS}' is not an address."
bridge="$(lower "${BRIDGE_ADDRESS}")"
network_id=""

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
# One JSON object per line; slurped later (no growing JSON on a command line).
: >"${work}/outputs.jsonl"
: >"${work}/flows.jsonl"

# From a call trace (callTracer withLog), skipping reverted frames and everything under them:
#   {k: "eth", from, to, value}  every call that moves ETH;
#   {k: "ev", data, chain}       every BridgeEvent, with the call chain that led to it: the
#                                address that CALLed the bridge, then the caller of that frame,
#                                and so on up to the transaction's sender.
# shellcheck disable=SC2016  # a jq program: $bridge, $topic... are jq variables
trace_program='
def frames($path):
  if (.error // null) != null then empty
  else
    ($path + [{type: ((.type // "") | ascii_upcase), from: ((.from // "") | ascii_downcase), to: ((.to // "") | ascii_downcase)}]) as $p
    | {f: ., p: $p}, ((.calls // [])[] | frames($p))
  end;
[frames([])] as $all
| ( $all[] | .f as $f | .p[-1] as $me
    | select(["CALL", "CREATE", "CREATE2", "SELFDESTRUCT"] | index($me.type))
    | select(((($f.value // "0x0") | ltrimstr("0x")) | test("^0*$")) | not)
    | {k: "eth", from: $me.from, to: $me.to, value: $f.value} ),
  ( $all[] | .p as $p
    | (.f.logs // [])[]
    | select(((.address // "") | ascii_downcase) == $bridge and (((.topics // [])[0] // "") | ascii_downcase) == $topic)
    | ([range(0; $p | length) | select($p[.].type == "CALL" and $p[.].to == $bridge)] | last) as $i
    | {k: "ev", data: ((.data // "") | ascii_downcase),
       chain: (if $i == null then [] else [range($i; -1; -1) as $j | $p[$j].from] end)} )'

first_block=""
for tx in "$@"; do
    [[ "${tx}" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "'${tx}' is not a transaction hash."
    receipt="$(cast receipt "${tx}" --json --rpc-url "${RPC_URL}")" || die "could not read the receipt of ${tx} from ${RPC_URL}."
    block="$(cast to-dec "$(jq -r '.blockNumber' <<<"${receipt}")")"
    [[ "${block}" =~ ^[0-9]+$ ]] || die "unexpected block number in the receipt of ${tx}."
    if [ -z "${first_block}" ] || [ "${block}" -lt "${first_block}" ]; then first_block="${block}"; fi

    trace="$(cast rpc debug_traceTransaction "${tx}" '{"tracer":"callTracer","tracerConfig":{"withLog":true}}' --rpc-url "${RPC_URL}")" \
        || die "could not trace ${tx} (debug_traceTransaction) on ${RPC_URL}."
    jq -c --arg bridge "${bridge}" --arg topic "${bridge_topic}" "${trace_program}" <<<"${trace}" >"${work}/trace.jsonl"
    jq -c 'select(.k == "eth")' "${work}/trace.jsonl" >>"${work}/flows.jsonl"
    # ERC-20 movements, from the receipt (only what was not reverted).
    jq -c --arg topic "${transfer_topic}" '.logs[]
        | select(((.topics[0] // "") | ascii_downcase) == $topic and (.topics | length) == 3 and ((.data // "") | test("^0x[0-9a-fA-F]{64}$")))
        | {k: "erc20", token: (.address | ascii_downcase), from: ("0x" + (.topics[1][-40:] | ascii_downcase)),
           to: ("0x" + (.topics[2][-40:] | ascii_downcase)), value: .data}' <<<"${receipt}" >>"${work}/flows.jsonl"

    receipt_data="$(jq -r --arg bridge "${bridge}" --arg topic "${bridge_topic}" \
        '.logs[] | select((.address | ascii_downcase) == $bridge and ((.topics[0] // "") | ascii_downcase) == $topic) | .data | ascii_downcase' <<<"${receipt}")"
    [ -n "${receipt_data}" ] || continue

    while IFS= read -r data; do
        [[ "${data}" =~ ^0x([0-9a-f]{64})+$ ]] || die "unexpected BridgeEvent data in ${tx}: ${data}"
        # The data carries the deposit count, so it identifies the event within the trace.
        chain="$(jq -c -s --arg d "${data}" '[.[] | select(.k == "ev" and .data == $d)] | if length == 1 then .[0].chain else null end' "${work}/trace.jsonl")"
        [ "${chain}" != "null" ] || die "could not find one of the BridgeEvents of ${tx} in its call trace."
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
        for v in "${leaf_type}" "${origin_network}" "${destination_network}" "${amount}"; do
            [[ "${v}" =~ ^[0-9]+$ ]] || die "unexpected value in a BridgeEvent of ${tx}: ${v}"
        done
        for v in "${origin_address}" "${destination_address}"; do
            [[ "${v}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "unexpected address in a BridgeEvent of ${tx}: ${v}"
        done
        [[ "${metadata}" =~ ^0x([0-9a-fA-F]{2})*$ ]] || die "unexpected metadata in a BridgeEvent of ${tx}: ${metadata}"
        # The asset the output takes out of the chain: ETH (a bridgeMessage's value, or ETH itself)
        # or the wrapped token the bridge burns; key "<origin_network>/<origin address>" for now.
        asset="${eth_asset}"
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
            if [ "${origin_network}" != "0" ] || [ "$(lower "${origin_address}")" != "0x0000000000000000000000000000000000000000" ]; then
                asset="${origin_network}/$(lower "${origin_address}")"
            fi
            echo "bridgeAsset   ${tx}: ${amount} of token (network ${origin_network}, ${origin_address}) to ${destination_address} on network 0" >&2
            ;;
        1)
            echo "bridgeMessage ${tx}: from ${origin_address} to ${destination_address} on network ${destination_network} (${amount} wei)" >&2
            ;;
        *)
            die "${tx} emits a BridgeEvent with an unknown leaf type ${leaf_type}."
            ;;
        esac
        [ "${amount}" != "0" ] || asset=""
        if [ "${leaf_type}" = "0" ]; then label="Transfer"; else label="Message"; fi
        jq -n -c --arg lt "${label}" \
            --argjson on "${origin_network}" --arg oa "$(cast to-check-sum-address "${origin_address}")" \
            --argjson dn "${destination_network}" --arg da "$(cast to-check-sum-address "${destination_address}")" \
            --arg amount "${amount}" --arg md "${metadata}" --arg asset "${asset}" --argjson chain "${chain}" --arg tx "${tx}" \
            '{leaf_type: $lt, token_info: {origin_network: $on, origin_token_address: $oa}, destination_network: $dn,
              destination_address: $da, amount: $amount, metadata: $md,
              _asset: (if $asset == "" then null else $asset end), _chain: $chain, _tx: $tx}' >>"${work}/outputs.jsonl"
    done <<<"${receipt_data}"
done

[ -s "${work}/outputs.jsonl" ] \
    || die "none of these transactions calls the bridge (${BRIDGE_ADDRESS}): move.sh must end with a call to bridgeAsset / bridgeMessage."

# --- origin_SC_funds ---------------------------------------------------------------------
before_block=$((first_block - 1))
: >"${work}/candidates.tsv" # asset \t contract \t loss (decimal)
: >"${work}/assets.tsv"     # asset \t token contract ("" for ETH)
while IFS= read -r asset; do
    if [ "${asset}" = "${eth_asset}" ]; then
        token=""
        flows_filter='select(.k == "eth")'
    else
        token="$(cast call "${BRIDGE_ADDRESS}" "getTokenWrappedAddress(uint32,address)(address)" "${asset%%/*}" "${asset#*/}" --rpc-url "${RPC_URL}")" \
            || die "could not read the wrapped token of (${asset%%/*}, ${asset#*/}) from the bridge."
        [[ "${token}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "unexpected wrapped token of (${asset%%/*}, ${asset#*/}): ${token}"
        token="$(lower "${token}")"
        flows_filter="select(.k == \"erc20\" and .token == \"${token}\")"
    fi
    printf '%s\t%s\n' "${asset}" "${token}" >>"${work}/assets.tsv"
    # Net change per address, as a bc expression in hex (ibase=16), then evaluated in one bc run.
    jq -r -s "[.[] | ${flows_filter} | (.value | ltrimstr(\"0x\") | ascii_upcase) as \$v
                | {a: .from, d: (\"-\" + \$v)}, {a: .to, d: (\"+\" + \$v)}]
              | group_by(.a)[] | [.[0].a, (\"0\" + (map(.d) | join(\"\")))] | @tsv" "${work}/flows.jsonl" >"${work}/net.tsv"
    [ -s "${work}/net.tsv" ] || continue
    { echo "ibase=16"; cut -f2 "${work}/net.tsv"; } | bc_run >"${work}/net.dec"
    paste <(cut -f1 "${work}/net.tsv") "${work}/net.dec" | while IFS=$'\t' read -r addr net; do
        [[ "${net}" == -* ]] || continue
        if [ "${addr}" = "${bridge}" ] || [ "${addr}" = "0x0000000000000000000000000000000000000000" ]; then continue; fi
        [ "$(cast code "${addr}" --block "${before_block}" --rpc-url "${RPC_URL}")" != "0x" ] || continue
        printf '%s\t%s\t%s\n' "${asset}" "${addr}" "${net#-}"
    done >>"${work}/candidates.tsv"
done < <(jq -r 'select(._asset != null) | ._asset' "${work}/outputs.jsonl" | sort -u)

# Resolve each output: the only candidate of its asset, or the first candidate up its call chain.
jq -R -s 'split("\n") | map(select(length > 0) | split("\t")) | reduce .[] as $c ({}; .[$c[0]] += [$c[1]])' \
    "${work}/candidates.tsv" >"${work}/candidates.json"
jq -c --slurpfile cands "${work}/candidates.json" '
    ($cands[0][._asset // ""] // []) as $c
    | . + {origin_SC_funds: (
        if ._asset == null then null
        elif ($c | length) == 1 then $c[0]
        elif ($c | length) > 1 then ([._chain[] | select(. as $a | $c | index($a))] | first)
        else null end)}' "${work}/outputs.jsonl" >"${work}/resolved.jsonl"
unresolved="$(jq -r 'select(._asset != null and .origin_SC_funds == null)
    | "  - \(._tx): \(.leaf_type) of \(.amount) (token \(.token_info.origin_network)/\(.token_info.origin_token_address)) to \(.destination_address)"' \
    "${work}/resolved.jsonl")"
if [ -n "${unresolved}" ]; then
    printf '%s\n' "${unresolved}" >&2
    die "could not find the contract that held the funds of the output(s) above: no contract (other than the bridge) lost that token in move.sh, or none of them is in the bridge call's call chain."
fi

# The outputs credited to a contract may not total more than it lost.
: >"${work}/sums.tsv" # asset \t contract \t credited (decimal)
while IFS=$'\t' read -r asset origin sum; do
    loss="$(awk -F'\t' -v a="${asset}" -v o="${origin}" '$1 == a && $2 == o { print $3 }' "${work}/candidates.tsv")"
    credited="$(printf '%s\n' "${sum}" | bc_run)"
    if [ "$(printf '%s > %s\n' "${credited}" "${loss}" | bc_run)" = "1" ]; then
        die "the outputs credited to ${origin} total ${credited} of asset ${asset}, but it only lost ${loss} in move.sh."
    fi
    echo "origin_SC_funds ${origin}: ${credited} of asset ${asset} (lost ${loss})" >&2
    printf '%s\t%s\t%s\n' "${asset}" "${origin}" "${credited}" >>"${work}/sums.tsv"
done < <(jq -r -s 'map(select(._asset != null)) | group_by([._asset, .origin_SC_funds])[]
    | [.[0]._asset, .[0].origin_SC_funds, (map(.amount) | join("+"))] | @tsv' "${work}/resolved.jsonl")

# Checksummed origins.
jq -r 'select(.origin_SC_funds != null) | .origin_SC_funds' "${work}/resolved.jsonl" | sort -u | while IFS= read -r a; do
    printf '%s\t%s\n' "${a}" "$(cast to-check-sum-address "${a}")"
done >"${work}/checksum.tsv"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' \
    "${work}/checksum.tsv" >"${work}/checksum.json"

jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: (.[0] + "|" + .[1]), value: .[2]}) | from_entries' \
    "${work}/sums.tsv" >"${work}/sums.json"

# shellcheck disable=SC2016  # a jq program
jq -s --slurpfile cs "${work}/checksum.json" --slurpfile sums "${work}/sums.json" '
    def uniq: reduce .[] as $v ([]; if any(.[]; . == $v) then . else . + [$v] end);
    map(select(._asset != null)) as $funded
    | {version: 1,
       outputs: map(del(._asset, ._chain, ._tx, .origin_SC_funds)),
       origin_SC_funds: [$funded | map(.origin_SC_funds) | uniq | .[] as $o
         | {address: $cs[0][$o],
            tokens: [$funded | map(select(.origin_SC_funds == $o) | ._asset) | uniq | .[] as $a
              | {token_info: (if $a == "eth"
                              then {origin_network: 0, origin_token_address: "0x0000000000000000000000000000000000000000"}
                              else ($funded | map(select(._asset == $a)) | first | .token_info) end),
                 amount: $sums[0][$a + "|" + $o]}]}]}' "${work}/resolved.jsonl"

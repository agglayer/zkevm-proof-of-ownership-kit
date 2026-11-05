#!/bin/bash
# Turns the simulated recovery transactions of a case into the "delta exits" file consumed by
# the exit_certificate tool in delta mode (options.deltaExitsFile, see
# https://github.com/agglayer/aggkit/blob/develop/docs/exit_certificate_deprecated_chain_sc_locked_funds.md),
# so that Polygon can build the recovery certificate straight from what you submit, without
# re-deriving token / destination / amount by hand.
#
# For every given tx (mined on the shadow-fork by recovery-tx/run.sh) it measures what the
# destination EOA ended up receiving, net of what it sent out in the same txs:
#   - native token: the value of every successful call to/from the destination, read from the
#     tx's call trace (debug_traceTransaction, callTracer). Internal ETH transfers emit no event,
#     so the receipt alone is not enough. Gas fees paid by the destination are NOT counted.
#   - ERC-20: the Transfer events of the receipt that have the destination as `to` / `from`.
# and resolves each token's origin through the bridge, as the certificate's token_info requires:
#   - wrappedTokenToTokenInfo(token) -> (originNetwork, originTokenAddress) for bridged tokens;
#   - networkID() + the token itself for tokens native to this chain;
#   - gasTokenNetwork()/gasTokenAddress() for the native token (zero / network 0 if absent).
# Amounts are merged per token (the delta mode rejects identical exits) and written as exits to
# the destination on --dest-network (L1 = 0 by default), with no metadata (the tool derives it).
#
# It fails loudly instead of guessing: a reverted tx, an NFT transfer to the destination, a token
# whose origin can't be read, a contract destination, no funds received, or (with --signatures) a
# destination without an entry in signatures.json.
#
# Usage:
#   recovery-tx/export-delta-exits.sh --bridge <bridge-address> --destination <EOA> \
#       --out cases/<case-id>/delta-exits.json [--summary <path>] \
#       [--signatures cases/<case-id>/signatures.json] [--dest-network <id>] \
#       [--allow-contract-destination] <tx-hash> [<tx-hash> ...]
#
# Environment: RPC_URL (default http://127.0.0.1:8545) — the shadow-fork started by setup/fork.sh.
# Requires: cast (Foundry), jq, bc.
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ZERO_ADDR="0x0000000000000000000000000000000000000000"
# keccak256("Transfer(address,address,uint256)")
TRANSFER_TOPIC="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ETH_KEY="native"

usage() {
    sed -n '/^# Usage:/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

bridge=""
destination=""
out=""
summary=""
signatures=""
dest_network=0
allow_contract=0
txs=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --bridge) bridge="${2:?--bridge requires an address}"; shift 2 ;;
    --destination) destination="${2:?--destination requires an address}"; shift 2 ;;
    --out) out="${2:?--out requires a path}"; shift 2 ;;
    --summary) summary="${2:?--summary requires a path}"; shift 2 ;;
    --signatures) signatures="${2:?--signatures requires a path}"; shift 2 ;;
    --dest-network) dest_network="${2:?--dest-network requires a network id}"; shift 2 ;;
    --allow-contract-destination) allow_contract=1; shift ;;
    -h | --help) usage ;;
    --*) die "unknown option $1" ;;
    *) txs+=("$1"); shift ;;
    esac
done

[ -n "$bridge" ] && [ -n "$destination" ] && [ -n "$out" ] && [ "${#txs[@]}" -gt 0 ] || usage
is_address "$bridge" || die "--bridge '$bridge' is not an address"
is_address "$destination" || die "--destination '$destination' is not an address"
[[ "$dest_network" =~ ^[0-9]+$ ]] || die "--dest-network must be a number"
for bin in cast jq bc; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in \$PATH (cast: install Foundry from https://getfoundry.sh)"
done
[ -n "$summary" ] || summary="$(dirname "$out")/recovery-summary.json"

dest_lc="$(lower "$destination")"
# topics are left-padded to 32 bytes
dest_topic="0x000000000000000000000000${dest_lc#0x}"

# The destination receives its funds on --dest-network with the SAME address: only safe for an EOA.
if [ "$(cast code "$destination" --rpc-url "$RPC_URL")" != "0x" ] && [ "$allow_contract" -ne 1 ]; then
    die "destination $destination is a contract on the fork: the exit goes to the same address on network ${dest_network}, where it may not be controlled by the owner. Use an EOA (or pass --allow-contract-destination if you control that address there too)"
fi

if [ -n "$signatures" ]; then
    [ -f "$signatures" ] || die "signatures file '$signatures' not found"
    jq -e --arg a "$dest_lc" 'any(.[]?; (.address // "" | ascii_downcase) == $a)' "$signatures" >/dev/null ||
        die "the destination $destination has no entry in $signatures: it must sign the ownership message too"
else
    echo "WARNING: no --signatures given, so the destination's signature is NOT checked." >&2
fi

dec() { cast to-dec "$1"; }

# net[key] = received - sent, in wei / token units (decimal strings, arbitrary precision via bc).
declare -A net
add() { # add <key> <signed amount>
    local cur="${net[$1]:-0}"
    net[$1]="$(echo "$cur + $2" | bc)"
}

senders=()
blocks=()
for tx in "${txs[@]}"; do
    [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "'$tx' is not a transaction hash"
    receipt="$(cast receipt "$tx" --json --rpc-url "$RPC_URL")" || die "could not read the receipt of $tx"
    status="$(jq -r '.status' <<<"$receipt")"
    case "$status" in 0x1 | 1 | success) ;; *) die "tx $tx did not succeed (status $status)" ;; esac
    senders+=("$(jq -r '.from' <<<"$receipt")")
    blocks+=("$(dec "$(jq -r '.blockNumber' <<<"$receipt")")")

    # Native token: sum the value of successful CALL/SELFDESTRUCT frames to / from the destination.
    trace="$(cast rpc debug_traceTransaction "$tx" '{"tracer":"callTracer"}' --rpc-url "$RPC_URL")" ||
        die "debug_traceTransaction failed for $tx (does the node support it? anvil does)"
    while read -r dir val; do
        [ -n "${dir:-}" ] || continue
        if [ "$dir" = in ]; then add "$ETH_KEY" "$(dec "$val")"; else add "$ETH_KEY" "-$(dec "$val")"; fi
    done < <(jq -r --arg d "$dest_lc" '
        def frames: select(.error == null) | ., ((.calls // [])[] | frames);
        frames
        | select((.type == "CALL" or .type == "SELFDESTRUCT") and (.value // "0x0") != "0x0" and (.value // "0x0") != "0x")
        | if ((.to // "") | ascii_downcase) == $d then "in " + .value
          elif ((.from // "") | ascii_downcase) == $d then "out " + .value
          else empty end' <<<"$trace")

    # An ERC-721 Transfer has the same signature but 4 topics: not supported by the exit tool.
    if jq -e --arg t "$TRANSFER_TOPIC" --arg d "$dest_topic" \
        'any(.logs[]?; .topics[0] == $t and (.topics | length) == 4 and .topics[2] == $d)' <<<"$receipt" >/dev/null; then
        die "tx $tx transfers an ERC-721 to the destination: only fungible tokens (native / ERC-20) are supported"
    fi
    # ERC-20: 3 topics (signature, from, to), amount in data.
    while read -r dir token data; do
        [ -n "${dir:-}" ] || continue
        key="$(lower "$token")"
        if [ "$dir" = in ]; then add "$key" "$(dec "$data")"; else add "$key" "-$(dec "$data")"; fi
    done < <(jq -r --arg t "$TRANSFER_TOPIC" --arg d "$dest_topic" '
        .logs[]? | select(.topics[0] == $t and (.topics | length) == 3)
        | if .topics[2] == $d and .topics[1] != $d then "in " + .address + " " + .data
          elif .topics[1] == $d and .topics[2] != $d then "out " + .address + " " + .data
          else empty end' <<<"$receipt")
done

# Resolve every token to its origin (token_info) and merge tokens that share it.
declare -A merged
call() { cast call "$bridge" "$@" --rpc-url "$RPC_URL"; }
for key in "${!net[@]}"; do
    amount="${net[$key]}"
    if [ "$(echo "$amount <= 0" | bc)" -eq 1 ]; then
        echo "WARNING: ${key}: net received is ${amount} (<= 0), skipped." >&2
        continue
    fi
    if [ "$key" = "$ETH_KEY" ]; then
        if origin_addr="$(call "gasTokenAddress()(address)" 2>/dev/null)" &&
            origin_net="$(call "gasTokenNetwork()(uint32)" 2>/dev/null)"; then
            origin_net="${origin_net%% *}"
        else
            echo "WARNING: bridge has no gasTokenAddress()/gasTokenNetwork(): native token taken as network 0 / zero address." >&2
            origin_net=0
            origin_addr="$ZERO_ADDR"
        fi
    else
        info="$(call "wrappedTokenToTokenInfo(address)(uint32,address)" "$key")" ||
            die "could not read wrappedTokenToTokenInfo($key) on the bridge $bridge"
        origin_net="$(sed -n 1p <<<"$info" | cut -d' ' -f1)"
        origin_addr="$(sed -n 2p <<<"$info" | cut -d' ' -f1)"
        if [ "$(lower "$origin_addr")" = "$(lower "$ZERO_ADDR")" ]; then
            # Not a wrapped token: native to this chain, its origin is this network and itself.
            origin_net="$(call "networkID()(uint32)")" || die "could not read networkID() on the bridge $bridge"
            origin_net="${origin_net%% *}"
            origin_addr="$key"
        fi
    fi
    mkey="${origin_net} $(lower "$origin_addr")"
    merged[$mkey]="$(echo "${merged[$mkey]:-0} + $amount" | bc)"
done

[ "${#merged[@]}" -gt 0 ] || die "the destination $destination received no funds in the given txs: nothing to export"

lines=""
for mkey in "${!merged[@]}"; do
    lines+="${mkey} ${merged[$mkey]}"$'\n'
done
mkdir -p "$(dirname "$out")" "$(dirname "$summary")"
# amounts stay strings: they can exceed the precision of a JSON number
printf '%s' "$lines" | LC_ALL=C sort | jq -R -s --arg dest "$destination" --argjson dn "$dest_network" '
    {bridge_exits: [split("\n")[] | select(length > 0) | split(" ") | {
        leaf_type: "Transfer",
        token_info: {origin_network: (.[0] | tonumber), origin_token_address: .[1]},
        dest_network: $dn,
        dest_address: $dest,
        amount: .[2]
    }]}' >"$out"

jq -n --arg bridge "$bridge" --arg dest "$destination" --argjson dn "$dest_network" \
    --arg chain "$(cast chain-id --rpc-url "$RPC_URL")" --arg latest "$(cast block-number --rpc-url "$RPC_URL")" \
    --arg txs "$(printf '%s\n' "${txs[@]}")" --arg senders "$(printf '%s\n' "${senders[@]}")" \
    --arg blocks "$(printf '%s\n' "${blocks[@]}")" --arg exits "$out" \
    '{generatedBy: "recovery-tx/export-delta-exits.sh", forkChainId: $chain, forkLatestBlock: $latest,
      bridge: $bridge, destination: $dest, destinationNetwork: $dn,
      transactions: ($txs | split("\n")), senders: ($senders | split("\n") | unique), blocks: ($blocks | split("\n")),
      deltaExitsFile: $exits}' >"$summary"

echo "Delta exits written to $out (summary: $summary):"
jq -r '.bridge_exits[] | "  network \(.token_info.origin_network) token \(.token_info.origin_token_address) -> \(.dest_address) (network \(.dest_network)): \(.amount)"' "$out"
echo
echo "Review these exits against what you expect to recover, then submit $out with the rest of"
echo "the package (see submission/SUBMIT.md)."

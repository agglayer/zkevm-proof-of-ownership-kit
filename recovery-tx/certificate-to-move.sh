#!/bin/bash
# Writes (to stdout) the move.sh that replays, on the shadow-fork, every bridge exit of an agglayer
# exit certificate (aggkit's exit_certificate tool: exit-certificate-signed.json /
# exit-certificate-full.json), in the certificate's order. Run on a fork that is at the state right
# before the certificate, it leaves the bridge's exit tree as it is after it: the generated script
# checks that each exit gets the next deposit count and, at the end, that the bridge's getRoot()
# equals the certificate's new_local_exit_root.
#
# For each exit, in order (one exit per block: the deposit counts follow the certificate):
#   - Transfer: the sender is the exit's dest_address (in the tool's certificate, the holder of the
#     funds on the L2) and it calls bridgeAsset with its own funds: ETH as the transaction's value, a
#     wrapped token is burned by the bridge, a token of the L2 itself is approved first.
#   - Message: the sender is the exit's token_info.origin_token_address (the L2 address that sent the
#     message) and it calls bridgeMessage with the exit's amount as value. The certificate only has
#     the hash of the metadata, so the raw metadata comes from --metadata (not needed when the hash
#     is the one of an empty metadata); a Message whose metadata is missing, or does not hash to the
#     certificate's value, is refused.
#   - A sender that does not hold the funds on the L2 (e.g. the exitAddress of the tool's SC-locked
#     exits, whose funds stay in the contracts) must be named with --fund: before each of its exits
#     the bridge is impersonated and gives it the exit's amount (ETH from the bridge's reserve, or a
#     mint of the wrapped token, as a claim would do). Not possible for a token of the L2 itself.
#     Without --fund such an exit fails when move.sh runs.
# The certificate's imported_bridge_exits are not read (the tool does not write any today).
#
# The generated script uses no state cheat code (no anvil_setBalance / anvil_setStorageAt): only
# transactions from impersonated accounts, eth_call and evm_mine, so it runs in the sandbox of
# recovery-tx/run.sh. It needs the fork of setup/fork.sh (gas is free there: a holder can bridge its
# whole ETH balance). ETH is taken to be the L2's gas token, as on zkEVM.
#
# Requires: jq, cast (Foundry toolchain), base64, od.
#
# Usage:
#   recovery-tx/certificate-to-move.sh <certificate.json> [--metadata <file>] [--fund <address>]... > move.sh
#   ./recovery-tx/run.sh move.sh
#
#   --metadata <file>  raw metadata of the exits, aligned with the certificate's bridge_exits: the
#                      tool's step-g-new-local-exit-root.json (its "bridgeExitMetadata", base64), or
#                      a JSON array of 0x-hex strings. Only the Message exits use it.
#   --fund <address>   see above; repeat it for several addresses.
#
# Env overrides:
#   BRIDGE_ADDRESS  the bridge of another network, e.g. a test one (default: the zkEVM bridge,
#                   0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe), as in build-recovery.sh
set -euo pipefail

BRIDGE_ADDRESS="${BRIDGE_ADDRESS:-0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe}"

for bin in jq cast base64 od; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "cast" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

usage="Usage: recovery-tx/certificate-to-move.sh <certificate.json> [--metadata <file>] [--fund <address>]... > move.sh"
die() { echo "Error: $*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

addr_re='^0x[0-9a-fA-F]{40}$'
hash_re='^0x[0-9a-f]{64}$'
uint32_re='^[0-9]{1,10}$'
uint256_re='^[0-9]{1,78}$'
hex_re='^0x([0-9a-f]{2})*$'
zero_address="0x0000000000000000000000000000000000000000"
empty_metadata_hash="0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"  # keccak256 of no bytes

certificate=""
metadata_file=""
funded=""   # newline-joined, lowercase
while [ "$#" -gt 0 ]; do
    case "$1" in
        --metadata)
            metadata_file="${2:?--metadata requires a file}"
            shift 2
            ;;
        --fund)
            [[ "${2:-}" =~ ${addr_re} ]] || die "--fund requires an address (0x + 40 hex digits)."
            funded+="$(lower "$2")"$'\n'
            shift 2
            ;;
        -h|--help)
            echo "${usage}"
            exit 0
            ;;
        -*)
            die "unknown option $1. ${usage}"
            ;;
        *)
            [ -z "${certificate}" ] || die "only one certificate file is expected. ${usage}"
            certificate="$1"
            shift
            ;;
    esac
done
[ -n "${certificate}" ] || die "${usage}"
[ -f "${certificate}" ] || die "'${certificate}' not found."
[[ "${BRIDGE_ADDRESS}" =~ ${addr_re} ]] || die "BRIDGE_ADDRESS is not an address: ${BRIDGE_ADDRESS}"
jq -e '(.bridge_exits | type) == "array"' "${certificate}" >/dev/null 2>&1 \
    || die "'${certificate}' is not a certificate (no bridge_exits array)."

# Every value below ends up in a shell script: nothing is used before it matches its pattern.
network_id="$(jq -r '.network_id' "${certificate}")"
height="$(jq -r '.height' "${certificate}")"
new_local_exit_root="$(jq -r '.new_local_exit_root | tostring | ascii_downcase' "${certificate}")"
exit_count="$(jq -r '.bridge_exits | length' "${certificate}")"
[[ "${network_id}" =~ ${uint32_re} ]] || die "the certificate's network_id is not a number: ${network_id}"
[[ "${height}" =~ ^[0-9]{1,20}$ ]] || die "the certificate's height is not a number: ${height}"
[[ "${new_local_exit_root}" =~ ${hash_re} ]] || die "the certificate's new_local_exit_root is not a 32-byte hash: ${new_local_exit_root}"
[ "${exit_count}" -gt 0 ] || die "the certificate has no bridge exits: nothing to replay."

# The raw metadata, one entry per exit: base64 in the tool's step G output, 0x-hex in a plain array.
metadata_kind="none"
if [ -n "${metadata_file}" ]; then
    [ -f "${metadata_file}" ] || die "'${metadata_file}' not found."
    metadata_kind="$(jq -r 'if type == "object" and (.bridgeExitMetadata | type) == "array" then "base64"
        elif type == "array" then "hex" else "unknown" end' "${metadata_file}" 2>/dev/null || echo unknown)"
    [ "${metadata_kind}" != "unknown" ] \
        || die "'${metadata_file}' is neither the tool's step-g-new-local-exit-root.json (bridgeExitMetadata) nor a JSON array of 0x-hex strings."
    metadata_count="$(jq -r 'if type == "object" then .bridgeExitMetadata else . end | length' "${metadata_file}")"
    [ "${metadata_count}" = "${exit_count}" ] \
        || die "'${metadata_file}' has ${metadata_count} entries and the certificate ${exit_count} bridge exits: they must be aligned."
fi

# One line per exit: index, leaf type, origin network, origin token, destination network,
# destination address, amount, metadata hash, raw metadata ("-" when there is none).
exits="$(jq -r --arg kind "${metadata_kind}" --slurpfile meta "${metadata_file:-/dev/null}" '
    (if $kind == "base64" then $meta[0].bridgeExitMetadata elif $kind == "hex" then $meta[0] else [] end) as $raw
    | .bridge_exits | to_entries[] | .key as $i | .value
    | [ $i, .leaf_type, (.token_info.origin_network // 0), (.token_info.origin_token_address // "0x0000000000000000000000000000000000000000"),
        .dest_network, .dest_address, .amount, (.metadata // "-"), ($raw[$i] // "-") ]
    | map(tostring | if . == "" then "-" else . end) | join(" ")' "${certificate}")"

# Prints the lines of the exits. Nothing is written to stdout unless every exit is valid.
emit_exits() {
    tokens=""   # newline-joined "<origin network>:<origin token>" of the wrapped tokens already resolved
    while IFS=' ' read -r i leaf_type origin_network origin_token dest_network dest_address amount metadata_hash raw extra; do
        [ -z "${extra}" ] || die "exit ${i}: unexpected spaces in its fields."
        [[ "${leaf_type}" =~ ^(Transfer|Message)$ ]] || die "exit ${i}: unknown leaf_type '${leaf_type}' (expected Transfer or Message)."
        [[ "${origin_network}" =~ ${uint32_re} ]] || die "exit ${i}: token_info.origin_network is not a number: ${origin_network}"
        [[ "${origin_token}" =~ ${addr_re} ]] || die "exit ${i}: token_info.origin_token_address is not an address: ${origin_token}"
        [[ "${dest_network}" =~ ${uint32_re} ]] || die "exit ${i}: dest_network is not a number: ${dest_network}"
        [[ "${dest_address}" =~ ${addr_re} ]] || die "exit ${i}: dest_address is not an address: ${dest_address}"
        [[ "${amount}" =~ ${uint256_re} ]] || die "exit ${i}: amount is not a decimal number: ${amount}"
        origin_token="$(lower "${origin_token}")"
        dest_address="$(lower "${dest_address}")"

        case "${leaf_type}" in
            Transfer)
                sender="${dest_address}"
                echo "# exit ${i}: Transfer of ${amount} of the token ${origin_token} (network ${origin_network}) to ${dest_address} (network ${dest_network})"
                fund=0
                if grep -Fxq "${sender}" <<<"${funded}"; then fund=1; fi
                if [ "${origin_token}" = "${zero_address}" ] && [ "${origin_network}" = "0" ]; then
                    [ "${network_id}" != "0" ] || die "exit ${i}: ETH of network 0 cannot be the gas token of a certificate of network 0."
                    [ "${fund}" -eq 0 ] || echo "fund_eth ${i} ${sender} ${amount}"
                    echo "bridge_eth ${i} ${sender} ${dest_network} ${dest_address} ${amount}"
                elif [ "${origin_network}" = "${network_id}" ]; then
                    [ "${fund}" -eq 0 ] || die "exit ${i}: --fund ${sender} is not possible for the token ${origin_token}: it is a token of the L2 itself, which the bridge cannot mint."
                    echo "approve_token ${i} ${sender} ${amount} ${origin_token}"
                    echo "bridge_token ${i} ${sender} ${dest_network} ${dest_address} ${amount} ${origin_token}"
                else
                    key="${origin_network}:${origin_token}"
                    n="$(grep -nFx "${key}" <<<"${tokens}" | cut -d: -f1 || true)"
                    if [ -z "${n}" ]; then
                        tokens+="${key}"$'\n'
                        n="$(grep -c . <<<"${tokens}")"
                        echo "TOKEN_${n}=\"\$(wrapped_token ${origin_network} ${origin_token})\""
                    fi
                    [ "${fund}" -eq 0 ] || echo "fund_token ${i} ${sender} ${amount} \"\${TOKEN_${n}}\""
                    echo "bridge_token ${i} ${sender} ${dest_network} ${dest_address} ${amount} \"\${TOKEN_${n}}\""
                fi
                ;;
            Message)
                # The leaf's origin is the L2 address that called bridgeMessage: it is the sender.
                [ "${origin_network}" = "${network_id}" ] \
                    || die "exit ${i}: a Message of network ${origin_network} cannot be sent from network ${network_id} (token_info.origin_network)."
                sender="${origin_token}"
                echo "# exit ${i}: Message from ${sender} to ${dest_address} (network ${dest_network}), with ${amount} wei"
                metadata_hash="0x$(lower "${metadata_hash#0x}")"
                [[ "${metadata_hash}" =~ ${hash_re} ]] || die "exit ${i}: the certificate's metadata is not a 32-byte hash: ${metadata_hash}"
                if [ "${metadata_kind}" = "none" ]; then
                    [ "${metadata_hash}" = "${empty_metadata_hash}" ] \
                        || die "exit ${i} is a Message and the certificate only has the hash of its metadata: give the raw metadata with --metadata <file> (the tool's step-g-new-local-exit-root.json)."
                    metadata="0x"
                elif [ "${raw}" = "-" ]; then
                    metadata="0x"
                elif [ "${metadata_kind}" = "base64" ]; then
                    [[ "${raw}" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "exit ${i}: its entry of '${metadata_file}' is not base64."
                    metadata="0x$(printf '%s' "${raw}" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
                else
                    metadata="$(lower "${raw}")"
                fi
                [[ "${metadata}" =~ ${hex_re} ]] || die "exit ${i}: its entry of '${metadata_file}' is not 0x-hex."
                [ "$(cast keccak "${metadata}")" = "${metadata_hash}" ] \
                    || die "exit ${i}: the metadata of '${metadata_file}' does not hash to the certificate's value (${metadata_hash}): is the file the one of this certificate?"
                if grep -Fxq "${sender}" <<<"${funded}" && [ "${amount}" != "0" ]; then
                    echo "fund_eth ${i} ${sender} ${amount}"
                fi
                echo "bridge_message ${i} ${sender} ${dest_network} ${dest_address} ${amount} ${metadata}"
                ;;
        esac
    done <<<"${exits}"

}
exit_lines="$(emit_exits)"

cat <<HEADER
#!/bin/bash
# Generated by recovery-tx/certificate-to-move.sh: do not edit, generate it again.
#
# Replays on the shadow-fork the ${exit_count} bridge exit(s) of the agglayer certificate of network
# ${network_id}, height ${height}, in the certificate's order, one per block. The fork must be at the
# state right before that certificate. It checks that each exit gets the next deposit count and
# that the bridge ends with the certificate's new_local_exit_root.
#
# Run it from the repo root with: ./recovery-tx/run.sh <this file>
set -euo pipefail

RPC_URL="\${RPC_URL:-http://127.0.0.1:8545}"
BRIDGE="${BRIDGE_ADDRESS}"
NETWORK_ID="${network_id}"
EXIT_COUNT="${exit_count}"
NEW_LOCAL_EXIT_ROOT="${new_local_exit_root}"
HEADER

cat <<'HELPERS'
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
BRIDGE_EVENT="0x501781209a1f8899323b96b4ef08b168df93e0a90c673d1e4cce39366cb62f9b"  # topic of BridgeEvent
GAS_LIMIT=10000000   # explicit: no gas estimation. Gas is free on the fork.

for bin in cast jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        exit 1
    fi
done

die() { echo "Error: $*" >&2; exit 1; }

# send <what> <from> <to> <value> [<signature> <args>...]: sends one transaction from the
# impersonated <from>, mines it and requires it to succeed. The receipt is left in ${receipt}.
send() {
    local what="$1" from="$2" to="$3" value="$4" hash
    shift 4
    cast rpc anvil_impersonateAccount "${from}" --rpc-url "${RPC_URL}" >/dev/null
    hash="$(cast send --async --unlocked --from "${from}" --value "${value}" --gas-limit "${GAS_LIMIT}" \
        --gas-price 0 --priority-gas-price 0 --rpc-url "${RPC_URL}" "${to}" "$@")" \
        || die "${what}: the fork refused the transaction from ${from} (does it hold the funds? see --fund in recovery-tx/certificate-to-move.sh)."
    cast rpc evm_mine --rpc-url "${RPC_URL}" >/dev/null
    receipt="$(cast rpc eth_getTransactionReceipt "${hash}" --rpc-url "${RPC_URL}")"
    [ "$(jq -r '.status // empty' <<<"${receipt}")" = "0x1" ] \
        || die "${what}: the transaction ${hash} from ${from} failed (does it hold the funds? see --fund in recovery-tx/certificate-to-move.sh)."
}

# The exit just sent must be the next leaf of the bridge's exit tree.
check_deposit_count() { # <exit index>
    local word expected
    word="$(jq -r --arg bridge "${BRIDGE}" --arg topic "${BRIDGE_EVENT}" \
        '[.logs[] | select((.address | ascii_downcase) == ($bridge | ascii_downcase) and .topics[0] == $topic)]
         | if length == 1 then .[0].data[450:514] else empty end' <<<"${receipt}")"
    [[ "${word}" =~ ^0{56}[0-9a-f]{8}$ ]] || die "exit $1: no BridgeEvent (or more than one) in its transaction."
    expected="$((FIRST_DEPOSIT_COUNT + $1))"
    [ "$((16#${word:56}))" = "${expected}" ] \
        || die "exit $1: it got the deposit count $((16#${word:56})), expected ${expected}."
    echo "exit $1: deposit count ${expected}, tx $(jq -r '.transactionHash' <<<"${receipt}")"
}

# wrapped_token <origin network> <origin token address>: prints the L2 address of the wrapped token.
wrapped_token() {
    local token
    token="$(cast call "${BRIDGE}" "getTokenWrappedAddress(uint32,address)(address)" "$1" "$2" --rpc-url "${RPC_URL}")"
    [[ "${token}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "unexpected answer from getTokenWrappedAddress($1, $2): ${token}"
    [ "${token}" != "${ZERO_ADDRESS}" ] || die "the bridge has no wrapped token for the token $2 of network $1."
    echo "${token}"
}

# The bridge gives <to> the funds of its next exit, as a claim would: ETH out of its reserve, or a
# mint of the wrapped token (only the bridge can mint it).
fund_eth() { # <exit index> <to> <amount>
    send "exit $1 (funding ${2} with ETH from the bridge)" "${BRIDGE}" "$2" "$3"
}
fund_token() { # <exit index> <to> <amount> <wrapped token>
    send "exit $1 (the bridge mints the token ${4} to ${2})" "${BRIDGE}" "$4" 0 "mint(address,uint256)" "$2" "$3"
}

bridge_eth() { # <exit index> <sender> <destination network> <destination address> <amount>
    send "exit $1 (bridgeAsset, ETH)" "$2" "${BRIDGE}" "$5" \
        "bridgeAsset(uint32,address,uint256,address,bool,bytes)" "$3" "$4" "$5" "${ZERO_ADDRESS}" false 0x
    check_deposit_count "$1"
}
bridge_token() { # <exit index> <sender> <destination network> <destination address> <amount> <L2 token>
    send "exit $1 (bridgeAsset, token ${6})" "$2" "${BRIDGE}" 0 \
        "bridgeAsset(uint32,address,uint256,address,bool,bytes)" "$3" "$4" "$5" "$6" false 0x
    check_deposit_count "$1"
}
# A token of the L2 itself is not burned but locked in the bridge, which needs an allowance.
approve_token() { # <exit index> <sender> <amount> <L2 token>
    send "exit $1 (approve of the token ${4})" "$2" "$4" 0 "approve(address,uint256)" "${BRIDGE}" "$3"
}
bridge_message() { # <exit index> <sender> <destination network> <destination address> <amount> <metadata>
    send "exit $1 (bridgeMessage)" "$2" "${BRIDGE}" "$5" \
        "bridgeMessage(uint32,address,bool,bytes)" "$3" "$4" false "$6"
    check_deposit_count "$1"
}

network="$(cast call "${BRIDGE}" "networkID()(uint32)" --rpc-url "${RPC_URL}")" \
    || die "could not read networkID() of the bridge ${BRIDGE} at ${RPC_URL}: is the fork running?"
network="${network%% *}"   # cast prints large numbers as "2000000 [2e6]"
[ "${network}" = "${NETWORK_ID}" ] || die "the bridge ${BRIDGE} is of network ${network}, the certificate of network ${NETWORK_ID}."
FIRST_DEPOSIT_COUNT="$(cast call "${BRIDGE}" "depositCount()(uint256)" --rpc-url "${RPC_URL}")"
FIRST_DEPOSIT_COUNT="${FIRST_DEPOSIT_COUNT%% *}"
[[ "${FIRST_DEPOSIT_COUNT}" =~ ^[0-9]{1,10}$ ]] || die "unexpected depositCount() of the bridge: ${FIRST_DEPOSIT_COUNT}"
echo "Replaying ${EXIT_COUNT} bridge exit(s) on ${BRIDGE}, from the deposit count ${FIRST_DEPOSIT_COUNT} ..."

HELPERS

printf '%s\n' "${exit_lines}"
cat <<'FOOTER'

count="$(cast call "${BRIDGE}" "depositCount()(uint256)" --rpc-url "${RPC_URL}")"
count="${count%% *}"
[ "${count}" = "$((FIRST_DEPOSIT_COUNT + EXIT_COUNT))" ] \
    || die "the bridge's deposit count is ${count}, expected $((FIRST_DEPOSIT_COUNT + EXIT_COUNT)): something else bridged meanwhile."
root="$(cast call "${BRIDGE}" "getRoot()(bytes32)" --rpc-url "${RPC_URL}")"
[ "${root}" = "${NEW_LOCAL_EXIT_ROOT}" ] \
    || die "the bridge's exit root is ${root}, the certificate's new_local_exit_root is ${NEW_LOCAL_EXIT_ROOT}: the fork was not at the state right before this certificate, or a replayed exit differs from the certificate's."
echo "Done: ${EXIT_COUNT} exit(s) replayed, deposit counts ${FIRST_DEPOSIT_COUNT}..$((count - 1)), exit root ${root} = the certificate's new_local_exit_root."
FOOTER

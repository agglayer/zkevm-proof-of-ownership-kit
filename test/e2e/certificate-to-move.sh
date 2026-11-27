#!/bin/bash
# End-to-end test of recovery-tx/certificate-to-move.sh: a small agglayer certificate (ETH, a
# wrapped token, a token of the L2 itself, a Message with and without ETH, and two exits of an
# address that holds nothing) is turned into a move.sh, which recovery-tx/run.sh replays on a
# shadow-fork of a throwaway chain with a mock bridge (MockBridge.sol). The test computes the
# expected exit root itself, from the certificate's fields, and move.sh must reach it.
# Negative cases are checked too. Nothing is left in the repo; everything is cleaned up on exit.
#
# Requires: docker (daemon running), cast, forge (Foundry), curl, jq, xxd, gzip.
#
# Usage (from anywhere): test/e2e/certificate-to-move.sh
#
# Env overrides:
#   ANVIL_IMAGE     Foundry image of the throwaway chain and the fork (default: ghcr.io/foundry-rs/foundry:v1.5.1)
#   CHAIN_PORT      host port of the throwaway chain (default: 18555)
#   ANVIL_PORT      host port for the shadow-fork (default: 18556)
#   E2E_WORKDIR     directory for logs/artifacts (default: a fresh mktemp dir, removed on
#                   exit unless E2E_KEEP=1). Set it to keep logs, e.g. for CI artifacts.
#   E2E_KEEP        1 = do not delete E2E_WORKDIR on exit
#
# WARNING: the private key below is the public, well-known anvil test key #0. It is worthless and
# used only against a local throwaway chain.
set -euo pipefail

e2e_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${e2e_dir}/../.." && pwd)"

ANVIL_IMAGE="${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:v1.5.1}"
CHAIN_PORT="${CHAIN_PORT:-18555}"
ANVIL_PORT="${ANVIL_PORT:-18556}"
E2E_KEEP="${E2E_KEEP:-0}"

missing=""
for bin in docker cast forge curl jq xxd gzip; do
    command -v "$bin" >/dev/null 2>&1 || missing="${missing} ${bin}"
done
if [ -n "${missing}" ]; then
    echo "Error: missing required tool(s):${missing}. Install Docker and the Foundry toolchain (https://getfoundry.sh)." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Error: docker daemon not reachable." >&2
    exit 1
fi

DEPLOYER_TEST_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # anvil account #0 - NOT a secret
ZERO="0x0000000000000000000000000000000000000000"
L1_TOKEN="0x00000000000000000000000000000000000000aa"        # the origin (network 0) of the wrapped token
ETH_HOLDER="0x1111111111111111111111111111111111111111"      # holds 3 ETH and bridges all of it
WRAPPED_HOLDER="0x2222222222222222222222222222222222222222"  # holds 500 of the wrapped token
NATIVE_HOLDER="0x3333333333333333333333333333333333333333"   # holds 70 of a token of the L2 itself
MESSAGE_SENDER="0x4444444444444444444444444444444444444444"  # sent two messages, one with 7 wei
EXIT_ADDRESS="0x5555555555555555555555555555555555555555"    # holds nothing: its exits need --fund
L1_DEST="0x6666666666666666666666666666666666666666"         # destination of the messages
EMPTY_HASH="c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"  # keccak256 of no bytes
MESSAGE_METADATA="0xdeadbeef"

WORKDIR="${E2E_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/zkevm-kit-e2e-cert.XXXXXX")}"
mkdir -p "${WORKDIR}"
CHAIN_NAME="zkevm-kit-e2e-chain-${CHAIN_PORT}"
ANVIL_NAME="zkevm-shadow-fork-${ANVIL_PORT}"   # name chosen by setup/fork.sh
FORK_LOG="${WORKDIR}/fork.log"
CHAIN_URL="http://127.0.0.1:${CHAIN_PORT}"
RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
fork_pid=""

step() { echo; echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

stop_fork() {
    if [ -n "${fork_pid}" ]; then kill "${fork_pid}" 2>/dev/null || true; fi
    docker rm -f "${ANVIL_NAME}" >/dev/null 2>&1 || true
    if [ -n "${fork_pid}" ]; then wait "${fork_pid}" 2>/dev/null || true; fi
    fork_pid=""
}

cleanup() {
    local rc=$?
    set +e
    [ "${rc}" -eq 0 ] || echo "e2e failed (exit ${rc}); logs in ${WORKDIR}" >&2
    stop_fork
    docker rm -f "${CHAIN_NAME}" >/dev/null 2>&1
    rm -rf "${WORKDIR}/forge"
    if [ -z "${E2E_WORKDIR:-}" ] && [ "${E2E_KEEP}" != "1" ]; then
        rm -rf "${WORKDIR}"
    fi
    return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_rpc() { # url seconds
    local i=0
    while [ "${i}" -lt "$2" ]; do
        if curl -sS -m 2 -X POST "$1" -H 'Content-Type: application/json' \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | jq -e '.result' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1; i=$((i + 1))
    done
    return 1
}

# expect_fail <description> <expected message> <cmd...>: the command must exit non-zero and say why.
expect_fail() {
    local desc="$1" message="$2"; shift 2
    if "$@" >"${WORKDIR}/neg.out" 2>&1; then
        cat "${WORKDIR}/neg.out" >&2
        fail "negative case did not fail: ${desc}"
    fi
    grep -q "${message}" "${WORKDIR}/neg.out" || { cat "${WORKDIR}/neg.out" >&2; fail "${desc}: expected the message '${message}'"; }
    echo "  ok (failed as expected): ${desc}"
}

fresh_fork() { # [<state dump to load>]
    stop_fork
    LOAD_STATE="${1:-}" L2_RPC_URL="${CHAIN_URL}" ANVIL_PORT="${ANVIL_PORT}" FORK_BLOCK="${STABLE_BLOCK}" \
        FORK_LOG="${FORK_LOG}" BLOCK_TIME=1 ANVIL_IMAGE="${ANVIL_IMAGE}" "${repo_root}/setup/fork.sh" >/dev/null 2>&1 &
    fork_pid=$!
    if ! wait_rpc "${RPC_URL}" 120; then
        tail -n 30 "${FORK_LOG}" >&2 || true
        fail "shadow-fork did not come up"
    fi
}

chain_send() { cast send --private-key "${DEPLOYER_TEST_KEY}" --rpc-url "${CHAIN_URL}" "$@" >/dev/null; }
deploy() { # <contract> [constructor args]
    local contract="$1"; shift
    (cd "${WORKDIR}/forge" && forge create "src/MockBridge.sol:${contract}" --root . --broadcast --json \
        --private-key "${DEPLOYER_TEST_KEY}" --rpc-url "${CHAIN_URL}" "$@") | jq -r '.deployedTo'
}
generate() { BRIDGE_ADDRESS="${BRIDGE}" "${repo_root}/recovery-tx/certificate-to-move.sh" "$@"; }
run_move() { RPC_URL="${RPC_URL}" ANVIL_IMAGE="${ANVIL_IMAGE}" "${repo_root}/recovery-tx/run.sh" "$1" </dev/null; }

# ---------------------------------------------------------------- 1. chain
step "1. Start the throwaway chain (anvil, ${ANVIL_IMAGE}) on 127.0.0.1:${CHAIN_PORT}"
docker rm -f "${CHAIN_NAME}" >/dev/null 2>&1 || true
# Published on all host interfaces so the fork's container reaches it through host.docker.internal
# (the node holds only a throwaway dev chain).
docker run -d --name "${CHAIN_NAME}" -p "${CHAIN_PORT}:8545" --entrypoint anvil "${ANVIL_IMAGE}" \
    --host 0.0.0.0 --port 8545 >/dev/null
wait_rpc "${CHAIN_URL}" 60 || fail "the chain did not answer on ${CHAIN_URL}"

# ---------------------------------------------------------------- 2. bridge, tokens, holders
step "2. Deploy the mock bridge and the tokens, fund the holders"
mkdir -p "${WORKDIR}/forge/src"
cp "${e2e_dir}/MockBridge.sol" "${WORKDIR}/forge/src/MockBridge.sol"
printf '[profile.default]\nsolc_version = "0.8.24"\nevm_version = "shanghai"\n' >"${WORKDIR}/forge/foundry.toml"
BRIDGE="$(deploy MockBridge)"
[[ "${BRIDGE}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "mock bridge deployment failed"
WRAPPED_TOKEN="$(deploy MockERC20 --constructor-args "${BRIDGE}")"
NATIVE_TOKEN="$(deploy MockERC20 --constructor-args "${BRIDGE}")"
[[ "${WRAPPED_TOKEN}" =~ ^0x[0-9a-fA-F]{40}$ && "${NATIVE_TOKEN}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "token deployment failed"
NATIVE_TOKEN="$(printf '%s' "${NATIVE_TOKEN}" | tr '[:upper:]' '[:lower:]')"
chain_send "${BRIDGE}" "setWrapped(uint32,address,address)" 0 "${L1_TOKEN}" "${WRAPPED_TOKEN}"
chain_send "${BRIDGE}" --value 5ether   # the bridge's ETH reserve
chain_send "${ETH_HOLDER}" --value 3ether
chain_send "${WRAPPED_TOKEN}" "mint(address,uint256)" "${WRAPPED_HOLDER}" 500
chain_send "${NATIVE_TOKEN}" "mint(address,uint256)" "${NATIVE_HOLDER}" 70
chain_send "${MESSAGE_SENDER}" --value 7wei
# A bridge made before the certificate: the certificate's exits start at the deposit count 1.
chain_send "${BRIDGE}" "bridgeAsset(uint32,address,uint256,address,bool,bytes)" 0 "${L1_DEST}" 1000 "${ZERO}" false 0x --value 1000
STABLE_BLOCK="$(cast block-number --rpc-url "${CHAIN_URL}")"
bridge_wei="$(cast balance "${BRIDGE}" --rpc-url "${CHAIN_URL}")"
echo "  bridge ${BRIDGE}, wrapped token ${WRAPPED_TOKEN}, L2 token ${NATIVE_TOKEN}, block ${STABLE_BLOCK}"

# ---------------------------------------------------------------- 3. certificate
step "3. Write the certificate and compute its exit root"
# One row per exit: leaf type, origin network, origin address, destination network, destination
# address, amount, raw metadata. The metadata of a certificate's exit is the hash, without 0x.
exits_table="0 0 ${ZERO} 0 ${ETH_HOLDER} 3000000000000000000 0x
0 0 ${L1_TOKEN} 0 ${WRAPPED_HOLDER} 500 0x
0 1 ${NATIVE_TOKEN} 0 ${NATIVE_HOLDER} 70 0x
1 1 ${MESSAGE_SENDER} 0 ${L1_DEST} 7 ${MESSAGE_METADATA}
1 1 ${MESSAGE_SENDER} 0 ${L1_DEST} 0 0x
0 0 ${ZERO} 0 ${EXIT_ADDRESS} 11 0x
0 0 ${L1_TOKEN} 0 ${EXIT_ADDRESS} 12 0x"

keccak_pair() { cast keccak "0x${1#0x}${2#0x}"; }
leaf_hash() { # the bridge's getLeafValue
    cast keccak "$(cast abi-encode --packed "f(uint8,uint32,address,uint32,address,uint256,bytes32)" "$1" "$2" "$3" "$4" "$5" "$6" "$(cast keccak "$7")")"
}
# Root of the depth-32 Merkle tree whose first leaves are the given ones (the rest are zero).
merkle_root() {
    local level="$*" zero="0x0000000000000000000000000000000000000000000000000000000000000000" height=0 next left
    while [ "${height}" -lt 32 ]; do
        next=""
        left=""
        for node in ${level}; do
            if [ -z "${left}" ]; then left="${node}"; else next="${next} $(keccak_pair "${left}" "${node}")"; left=""; fi
        done
        [ -z "${left}" ] || next="${next} $(keccak_pair "${left}" "${zero}")"
        level="${next}"
        zero="$(keccak_pair "${zero}" "${zero}")"
        height=$((height + 1))
    done
    echo "${level# }"
}

leaves="$(leaf_hash 0 0 "${ZERO}" 0 "${L1_DEST}" 1000 0x)"   # the bridge made in step 2
exits_json="[]"
metadata_hex="[]"
while read -r leaf_type origin_network origin_address dest_network dest_address amount metadata; do
    leaves="${leaves} $(leaf_hash "${leaf_type}" "${origin_network}" "${origin_address}" "${dest_network}" "${dest_address}" "${amount}" "${metadata}")"
    metadata_hash="$(cast keccak "${metadata}")"
    exits_json="$(jq -c --arg type "${leaf_type}" --argjson on "${origin_network}" --arg oa "${origin_address}" --argjson dn "${dest_network}" \
        --arg da "${dest_address}" --arg amount "${amount}" --arg hash "${metadata_hash#0x}" \
        '. + [{leaf_type: (if $type == "0" then "Transfer" else "Message" end), token_info: {origin_network: $on, origin_token_address: $oa},
               dest_network: $dn, dest_address: $da, amount: $amount, metadata: $hash}]' <<<"${exits_json}")"
    metadata_hex="$(jq -c --arg m "${metadata}" '. + [$m]' <<<"${metadata_hex}")"
done <<<"${exits_table}"
# shellcheck disable=SC2086  # one argument per leaf
EXPECTED_ROOT="$(merkle_root ${leaves})"
[ "$(jq -r '.[0].metadata' <<<"${exits_json}")" = "${EMPTY_HASH}" ] || fail "unexpected hash of an empty metadata"

CERT="${WORKDIR}/exit-certificate-signed.json"
jq -n --arg root "${EXPECTED_ROOT}" --argjson exits "${exits_json}" \
    '{network_id: 1, height: 0, prev_local_exit_root: "0x0000000000000000000000000000000000000000000000000000000000000000",
      new_local_exit_root: $root, bridge_exits: $exits, imported_bridge_exits: []}' >"${CERT}"
# The raw metadata in the two accepted formats: the tool's step G output (base64) and a hex array.
METADATA="${WORKDIR}/step-g-new-local-exit-root.json"
jq -n --arg m "$(printf '\xde\xad\xbe\xef' | base64)" '{bridgeExitMetadata: ["", "", "", $m, "", "", ""]}' >"${METADATA}"
printf '%s\n' "${metadata_hex}" >"${WORKDIR}/metadata-hex.json"
echo "  7 exits, expected exit root ${EXPECTED_ROOT}"

# ---------------------------------------------------------------- 4. generate
step "4. recovery-tx/certificate-to-move.sh"
MOVE="${WORKDIR}/move.sh"
generate "${CERT}" --metadata "${METADATA}" --fund "${EXIT_ADDRESS}" >"${MOVE}"
bash -n "${MOVE}" || fail "the generated move.sh is not valid bash"
generate "${CERT}" --fund "${EXIT_ADDRESS}" --metadata "${WORKDIR}/metadata-hex.json" >"${WORKDIR}/move-again.sh"
cmp -s "${MOVE}" "${WORKDIR}/move-again.sh" || fail "two generations (base64 and hex metadata) differ"
[ "$(grep -c '^bridge_[a-z]* [0-9]' "${MOVE}")" = "7" ] || fail "expected 7 bridge calls in move.sh"
# The exits are in the certificate's order, each sent by the address that holds its funds.
grep '^bridge_[a-z]* [0-9]' "${MOVE}" | awk '{print $2, $3}' >"${WORKDIR}/order.out"
expected_order="0 ${ETH_HOLDER}
1 ${WRAPPED_HOLDER}
2 ${NATIVE_HOLDER}
3 ${MESSAGE_SENDER}
4 ${MESSAGE_SENDER}
5 ${EXIT_ADDRESS}
6 ${EXIT_ADDRESS}"
[ "$(cat "${WORKDIR}/order.out")" = "${expected_order}" ] || { cat "${WORKDIR}/order.out" >&2; fail "unexpected exit order / senders in move.sh"; }
if grep -Eq 'anvil_set|hardhat_set|evm_snapshot' "${MOVE}"; then fail "move.sh uses a state cheat code"; fi

expect_fail "a Message without its raw metadata is refused" "give the raw metadata with --metadata" generate "${CERT}"
jq '.[3] = "0xdeadbeee"' "${WORKDIR}/metadata-hex.json" >"${WORKDIR}/metadata-wrong.json"
expect_fail "a metadata that does not hash to the certificate's value is refused" "does not hash to the certificate's value" \
    generate "${CERT}" --metadata "${WORKDIR}/metadata-wrong.json"
jq '.[0:3]' "${WORKDIR}/metadata-hex.json" >"${WORKDIR}/metadata-short.json"
expect_fail "a metadata file not aligned with the exits is refused" "they must be aligned" \
    generate "${CERT}" --metadata "${WORKDIR}/metadata-short.json"
expect_fail "--fund is refused for a token of the L2 itself" "token of the L2 itself" \
    generate "${CERT}" --metadata "${METADATA}" --fund "${NATIVE_HOLDER}"
jq '.bridge_exits[0].dest_address = "0x1111; touch /tmp/x"' "${CERT}" >"${WORKDIR}/cert-bad.json"
expect_fail "a field that is not what it should be is refused" "exit 0:" generate "${WORKDIR}/cert-bad.json" --metadata "${METADATA}"
if grep -q '^#!/bin/bash' "${WORKDIR}/neg.out"; then fail "a refused certificate still wrote a script"; fi

# ---------------------------------------------------------------- 5. replay
step "5. Replay on the shadow-fork (block ${STABLE_BLOCK}) with recovery-tx/run.sh"
# Negative: without --fund, the exits of the address that holds nothing fail (after the first five).
generate "${CERT}" --metadata "${METADATA}" >"${WORKDIR}/move-nofund.sh"
fresh_fork
expect_fail "an exit whose sender does not hold the funds fails" "exit 5 (bridgeAsset, ETH)" run_move "${WORKDIR}/move-nofund.sh"

# Negative: another new_local_exit_root (e.g. a fork that is not at the state before the certificate).
jq '.new_local_exit_root = "0x00000000000000000000000000000000000000000000000000000000000000ff"' "${CERT}" >"${WORKDIR}/cert-root.json"
generate "${WORKDIR}/cert-root.json" --metadata "${METADATA}" --fund "${EXIT_ADDRESS}" >"${WORKDIR}/move-root.sh"
fresh_fork
expect_fail "a bridge that does not end with the certificate's exit root fails" "the certificate's new_local_exit_root is" run_move "${WORKDIR}/move-root.sh"

fresh_fork
[ "$(cast call "${BRIDGE}" 'depositCount()(uint256)' --rpc-url "${RPC_URL}")" = "1" ] || fail "the fork should start with 1 deposit"
supply_before="$(cast call "${WRAPPED_TOKEN}" 'totalSupply()(uint256)' --rpc-url "${RPC_URL}")"   # 500
run_move "${MOVE}" | tee "${WORKDIR}/move.out"
i=0
while [ "${i}" -lt 7 ]; do
    grep -q "^exit ${i}: deposit count $((i + 1)), tx 0x" "${WORKDIR}/move.out" || fail "exit ${i} did not get the deposit count $((i + 1))"
    i=$((i + 1))
done
[ "$(cast call "${BRIDGE}" 'depositCount()(uint256)' --rpc-url "${RPC_URL}")" = "8" ] || fail "expected 8 deposits after the replay"
[ "$(cast call "${BRIDGE}" 'getRoot()(bytes32)' --rpc-url "${RPC_URL}")" = "${EXPECTED_ROOT}" ] || fail "the bridge's exit root is not the certificate's"

# The holders paid with their own funds; the funded address ends as it started (with nothing).
balance() { cast balance "$1" --rpc-url "${RPC_URL}"; }
token_balance() { cast call "$1" 'balanceOf(address)(uint256)' "$2" --rpc-url "${RPC_URL}"; }
[ "$(balance "${ETH_HOLDER}")" = "0" ] || fail "the ETH holder still has ETH"
[ "$(token_balance "${WRAPPED_TOKEN}" "${WRAPPED_HOLDER}")" = "0" ] || fail "the wrapped token holder still has tokens"
[ "$(token_balance "${NATIVE_TOKEN}" "${NATIVE_HOLDER}")" = "0" ] || fail "the L2 token holder still has tokens"
[ "$(token_balance "${NATIVE_TOKEN}" "${BRIDGE}")" = "70" ] || fail "the L2 token is not locked in the bridge"
[ "$(balance "${MESSAGE_SENDER}")" = "0" ] || fail "the message sender still has ETH"
[ "$(balance "${EXIT_ADDRESS}")" = "0" ] || fail "the funded address kept ETH"
[ "$(token_balance "${WRAPPED_TOKEN}" "${EXIT_ADDRESS}")" = "0" ] || fail "the funded address kept tokens"
# Wrapped: 500 burned (the 12 funded were minted and burned). ETH: 3 ETH + 7 wei in (the 11 funded went out and back).
[ "$(cast call "${WRAPPED_TOKEN}" 'totalSupply()(uint256)' --rpc-url "${RPC_URL}")" = "$((supply_before - 500))" ] || fail "unexpected wrapped token supply"
[ "$(balance "${BRIDGE}")" = "$((bridge_wei + 3000000000000000000 + 7))" ] || fail "unexpected ETH balance of the bridge"
echo "  7 exits replayed with the deposit counts 1..7, exit root and balances as expected"

# The senders of the bridge transactions, as recovery-tx/list-impersonated.sh sees them.
# shellcheck disable=SC2046  # one argument per tx hash
RPC_URL="${RPC_URL}" "${repo_root}/recovery-tx/list-impersonated.sh" $(sed -n 's/^exit [0-9]*: .* tx \(0x[0-9a-f]*\)$/\1/p' "${WORKDIR}/move.out") >"${WORKDIR}/list.out"
for sender in "${ETH_HOLDER}" "${WRAPPED_HOLDER}" "${NATIVE_HOLDER}" "${MESSAGE_SENDER}" "${EXIT_ADDRESS}"; do
    grep -qi "^${sender}$" "${WORKDIR}/list.out" || fail "${sender} is not listed as a sender"
done

# Negative: a second replay on the same fork fails (the holders' funds are gone).
expect_fail "replaying the certificate twice on the same fork fails" "exit 0 (bridgeAsset, ETH)" run_move "${MOVE}"

# ---------------------------------------------------------------- 6. state for submission/verify.sh
step "6. The state after the certificate, as submission/verify.sh loads it (LOAD_STATE)"
# Dumped the way submission/helpers/generate.sh does (anvil_dumpState: hex, gzip on most versions).
STATE="${WORKDIR}/anvil-state.json"
dump_hex="$(cast rpc anvil_dumpState --rpc-url "${RPC_URL}" | jq -r .)"
[[ "${dump_hex}" =~ ^0x([0-9a-fA-F]{2})+$ ]] || fail "unexpected anvil_dumpState result"
if [[ "${dump_hex}" == 0x1f8b* ]]; then
    printf '%s' "${dump_hex#0x}" | xxd -r -p | gzip -dc >"${STATE}"
else
    printf '%s' "${dump_hex#0x}" | xxd -r -p >"${STATE}"
fi
fresh_fork "${STATE}"
[ "$(cast call "${BRIDGE}" 'depositCount()(uint256)' --rpc-url "${RPC_URL}")" = "8" ] || fail "the loaded state does not have the 8 deposits"
[ "$(cast call "${BRIDGE}" 'getRoot()(bytes32)' --rpc-url "${RPC_URL}")" = "${EXPECTED_ROOT}" ] || fail "the loaded state does not have the certificate's exit root"
[ "$(balance "${ETH_HOLDER}")" = "0" ] || fail "the loaded state gives the ETH holder its ETH back"
echo "  a fork that loads the dumped state starts after the certificate (8 deposits, same exit root)"

step "E2E PASSED"

#!/bin/bash
# End-to-end test of the kit against a throwaway geth --dev node (stand-in for the halted
# zkEVM mainnet), using only test keys.
#
# Flow: geth (docker) -> deploy a mock bridge and a "locked" Vault + fund it -> head stays fixed
# -> start setup/fork.sh (anvil in docker) with FORK_BLOCK = that head -> run a temporary case
# (move.sh impersonating the Vault owner, which makes the Vault call bridgeAsset + bridgeMessage)
# with recovery-tx/run.sh -> build recovery.json with build-recovery.sh -> sign with
# ownership-proof/sign-message.sh -> check with list-impersonated.sh / verify-signature.sh.
# Negative cases are checked too. Nothing is left in the repo; everything is cleaned up on exit.
#
# Requires: docker (daemon running), cast, forge (Foundry), curl, jq.
#
# Usage (from anywhere): test/e2e/run.sh
#
# Env overrides:
#   GETH_IMAGE      geth image (default: ethereum/client-go:v1.16.7)
#   GETH_PORT       host port for geth HTTP RPC (default: 18545)
#   ANVIL_PORT      host port for the shadow-fork (default: 18546)
#   E2E_WORKDIR     directory for logs/artifacts (default: a fresh mktemp dir, removed on
#                   exit unless E2E_KEEP=1). Set it to keep logs, e.g. for CI artifacts.
#   E2E_KEEP        1 = do not delete E2E_WORKDIR on exit
#   GITHUB_ENV      if set, STABLE_BLOCK is appended to it
#
# WARNING: the private keys below are the public, well-known anvil/hardhat test keys.
# They are worthless and used only against local throwaway chains.
set -euo pipefail

e2e_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${e2e_dir}/../.." && pwd)"

GETH_IMAGE="${GETH_IMAGE:-ethereum/client-go:v1.16.7}"
GETH_PORT="${GETH_PORT:-18545}"
ANVIL_PORT="${ANVIL_PORT:-18546}"
E2E_KEEP="${E2E_KEEP:-0}"

missing=""
for bin in docker cast forge curl jq; do
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

# Public test keys (anvil account #0, key 0x..01, anvil account #2) - NOT secrets.
OWNER_TEST_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEST_TEST_KEY="0x0000000000000000000000000000000000000000000000000000000000000001"  # private key 1: empty balance on anvil
ATTACKER_TEST_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
OWNER="$(cast wallet address --private-key "${OWNER_TEST_KEY}")"
DEST="$(cast wallet address --private-key "${DEST_TEST_KEY}")"
ATTACKER="$(cast wallet address --private-key "${ATTACKER_TEST_KEY}")"
FUND_AMOUNT="5ether"
ASSET_WEI="4000000000000000000"   # what the case bridges with bridgeAsset (the vault keeps the rest)
MESSAGE_NETWORK=7
MESSAGE_METADATA="0xdeadbeef"
NONCE=424242

WORKDIR="${E2E_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/zkevm-kit-e2e.XXXXXX")}"
mkdir -p "${WORKDIR}"
GETH_NAME="zkevm-kit-e2e-geth-${GETH_PORT}"
ANVIL_NAME="zkevm-shadow-fork-${ANVIL_PORT}"   # name chosen by setup/fork.sh
FORK_LOG="${WORKDIR}/fork.log"
GETH_LOG="${WORKDIR}/geth.log"
CASE_DIR="${WORKDIR}/case"
KS_DIR="${WORKDIR}/keystore"
fork_pid=""

step() { echo; echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
    local rc=$?
    set +e
    if [ "${rc}" -ne 0 ]; then
        echo "e2e failed (exit ${rc}); logs in ${WORKDIR}" >&2
        docker logs "${GETH_NAME}" >"${GETH_LOG}" 2>&1
    fi
    [ -n "${fork_pid}" ] && kill "${fork_pid}" 2>/dev/null
    docker rm -f "${ANVIL_NAME}" >/dev/null 2>&1
    if [ "${rc}" -eq 0 ]; then docker logs "${GETH_NAME}" >"${GETH_LOG}" 2>&1; fi
    docker rm -f "${GETH_NAME}" >/dev/null 2>&1
    [ -n "${fork_pid}" ] && wait "${fork_pid}" 2>/dev/null
    rm -rf "${KS_DIR}" "${CASE_DIR}" "${WORKDIR}/forge"
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

# expect_fail <description> <cmd...>: the command must exit non-zero.
expect_fail() {
    local desc="$1"; shift
    if "$@" >"${WORKDIR}/neg.out" 2>&1; then
        cat "${WORKDIR}/neg.out" >&2
        fail "negative case did not fail: ${desc}"
    fi
    echo "  ok (failed as expected): ${desc}"
}

balance_wei() { cast balance "$1" --rpc-url "$2"; }

# ---------------------------------------------------------------- 1. geth
step "1. Start geth --dev (${GETH_IMAGE}) on 127.0.0.1:${GETH_PORT}"
GETH_URL="http://127.0.0.1:${GETH_PORT}"
docker rm -f "${GETH_NAME}" >/dev/null 2>&1 || true
# Published on all host interfaces so containers reaching host.docker.internal can use it
# (the node holds only a throwaway dev chain).
docker run -d --name "${GETH_NAME}" -p "${GETH_PORT}:8545" "${GETH_IMAGE}" \
    --dev --http --http.addr 0.0.0.0 --http.port 8545 \
    --http.api eth,net,web3 --http.vhosts '*' --http.corsdomain '*' \
    --nodiscover --maxpeers 0 >/dev/null
wait_rpc "${GETH_URL}" 60 || fail "geth did not answer on ${GETH_URL}"
export ETH_RPC_URL="${GETH_URL}"
echo "  chainId $(cast chain-id --rpc-url "${GETH_URL}")"

# ---------------------------------------------------------------- 2. vault
step "2. Fund the owner, deploy the mock bridge and the locked Vault"
dev_acct="$(cast rpc eth_accounts --rpc-url "${GETH_URL}" | jq -r '.[0]')"
[[ "${dev_acct}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "geth dev account not found"
# A fresh geth --dev answers "transaction indexing is in progress" to receipt lookups until
# its first block exists, so the first tx is sent --async and we wait for the indexer.
cast send --async --unlocked --from "${dev_acct}" "${OWNER}" --value 100ether --rpc-url "${GETH_URL}" >/dev/null
i=0
until curl -sS -m 2 -X POST "${GETH_URL}" -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_getTransactionByHash","params":["0x0000000000000000000000000000000000000000000000000000000000000001"],"id":1}' \
    | jq -e 'has("error") | not' >/dev/null 2>&1; do
    i=$((i + 1)); [ "${i}" -lt 60 ] || fail "geth tx indexer never became ready"
    sleep 1
done
cast send --unlocked --from "${dev_acct}" "${ATTACKER}" --value 10ether --rpc-url "${GETH_URL}" >/dev/null

mkdir -p "${WORKDIR}/forge/src"
cp "${e2e_dir}/Vault.sol" "${WORKDIR}/forge/src/Vault.sol"
cp "${e2e_dir}/MockBridge.sol" "${WORKDIR}/forge/src/MockBridge.sol"
printf '[profile.default]\nsolc_version = "0.8.24"\nevm_version = "shanghai"\n' >"${WORKDIR}/forge/foundry.toml"
BRIDGE="$(cd "${WORKDIR}/forge" && forge create src/MockBridge.sol:MockBridge --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" | jq -r '.deployedTo')"
[[ "${BRIDGE}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "mock bridge deployment failed"
# The scripts look for the zkEVM bridge; on this test chain it is the mock (test-only override).
export BRIDGE_ADDRESS="${BRIDGE}"
deploy_json="$(cd "${WORKDIR}/forge" && forge create src/Vault.sol:Vault --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}")"
VAULT="$(printf '%s' "${deploy_json}" | jq -r '.deployedTo')"
[[ "${VAULT}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "vault deployment failed"
cast send "${VAULT}" --value "${FUND_AMOUNT}" --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
# A second vault owned by a CONTRACT (a stand-in for a multisig): moving its funds means
# impersonating that contract, which cannot sign, so the verifier asks for a manual review.
CONTROLLER="$(cd "${WORKDIR}/forge" && forge create src/Vault.sol:Vault --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" | jq -r '.deployedTo')"
VAULT2="$(cd "${WORKDIR}/forge" && forge create src/Vault.sol:Vault --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" | jq -r '.deployedTo')"
[[ "${CONTROLLER}" =~ ^0x[0-9a-fA-F]{40}$ && "${VAULT2}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "controller / vault2 deployment failed"
cast send "${VAULT2}" --value 1ether --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
cast send "${VAULT2}" "transferOwnership(address)" "${CONTROLLER}" --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
vault2_wei="$(balance_wei "${VAULT2}" "${GETH_URL}")"
echo "  bridge ${BRIDGE}; vault ${VAULT}, owner ${OWNER}; vault2 ${VAULT2} owned by the contract ${CONTROLLER}"

# ERC-20s held by the vault: one native to this chain (the bridge locks it) and one wrapped (a token
# of network 0, which the bridge burns).
L1_TOKEN="0x1111111111111111111111111111111111111111"
NATIVE_TOKEN="$(cd "${WORKDIR}/forge" && forge create src/MockBridge.sol:MockERC20 --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" --constructor-args "${BRIDGE}" | jq -r '.deployedTo')"
WRAPPED_TOKEN="$(cd "${WORKDIR}/forge" && forge create src/MockBridge.sol:MockERC20 --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" --constructor-args "${BRIDGE}" | jq -r '.deployedTo')"
[[ "${NATIVE_TOKEN}" =~ ^0x[0-9a-fA-F]{40}$ && "${WRAPPED_TOKEN}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "token deployment failed"
cast send "${BRIDGE}" "setWrapped(uint32,address,address)" 0 "${L1_TOKEN}" "${WRAPPED_TOKEN}" --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
cast send "${NATIVE_TOKEN}" "mint(address,uint256)" "${VAULT}" 1000 --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
cast send "${WRAPPED_TOKEN}" "mint(address,uint256)" "${VAULT}" 500 --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
echo "  tokens: native ${NATIVE_TOKEN}, wrapped ${WRAPPED_TOKEN} (of ${L1_TOKEN} on network 0)"

vault_wei="$(balance_wei "${VAULT}" "${GETH_URL}")"
[ "${vault_wei}" = "5000000000000000000" ] || fail "vault balance on geth is ${vault_wei}"
[ "$(cast call "${VAULT}" 'owner()(address)' --rpc-url "${GETH_URL}")" = "$(cast to-check-sum-address "${OWNER}")" ] \
    || fail "vault owner mismatch"

# ---------------------------------------------------------------- 3. stable block
step "3. Record the stable head block"
b1="$(cast block-number --rpc-url "${GETH_URL}")"
sleep 3
STABLE_BLOCK="$(cast block-number --rpc-url "${GETH_URL}")"
[ "${b1}" = "${STABLE_BLOCK}" ] || fail "geth head is still moving (${b1} -> ${STABLE_BLOCK})"
echo "${STABLE_BLOCK}" >"${WORKDIR}/stable_block"
[ -n "${GITHUB_ENV:-}" ] && echo "STABLE_BLOCK=${STABLE_BLOCK}" >>"${GITHUB_ENV}"
echo "  STABLE_BLOCK=${STABLE_BLOCK}"

# ---------------------------------------------------------------- 4. fork
step "4. Start setup/fork.sh at block ${STABLE_BLOCK}"
L2_RPC_URL="${GETH_URL}" ANVIL_PORT="${ANVIL_PORT}" FORK_BLOCK="${STABLE_BLOCK}" \
    FORK_LOG="${FORK_LOG}" BLOCK_TIME=1 "${repo_root}/setup/fork.sh" >/dev/null 2>&1 &
fork_pid=$!
RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
if ! wait_rpc "${RPC_URL}" 120; then
    tail -n 30 "${FORK_LOG}" >&2 || true
    fail "shadow-fork did not come up"
fi
export RPC_URL ETH_RPC_URL="${RPC_URL}"
grep -q "WARNING: FORK_BLOCK=${STABLE_BLOCK}" "${FORK_LOG}" || fail "fork.log lacks the FORK_BLOCK warning"
[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "${vault_wei}" ] || fail "vault balance differs on the fork"
echo "  fork up, vault funded on the fork"

# ---------------------------------------------------------------- 5. case
step "5. Temporary case: impersonate the owner, the vault calls bridgeAsset + bridgeMessage"
mkdir -p "${CASE_DIR}"
cp -r "${repo_root}/cases/_template/." "${CASE_DIR}/"
# bridge_calls <vault> <from> <asset destination> <asset wei>: the body of a move.sh in which <from>
# makes <vault> bridge <asset wei> of ETH to <asset destination> on network 0, then send a message.
bridge_calls() {
    local asset_call message_call
    asset_call="$(cast calldata "bridgeAsset(uint32,address,uint256,address,bool,bytes)" 0 "$3" "$4" 0x0000000000000000000000000000000000000000 true 0x)"
    message_call="$(cast calldata "bridgeMessage(uint32,address,bool,bytes)" "${MESSAGE_NETWORK}" "${DEST}" true "${MESSAGE_METADATA}")"
    cat <<CALLS
cast rpc anvil_impersonateAccount "$2" --rpc-url "\${RPC_URL}" >/dev/null
cast send --unlocked --from "$2" "$1" "execute(address,uint256,bytes)" "${BRIDGE}" "$4" "${asset_call}" --json --rpc-url "\${RPC_URL}"
cast send --unlocked --from "$2" "$1" "execute(address,uint256,bytes)" "${BRIDGE}" 0 "${message_call}" --json --rpc-url "\${RPC_URL}"
CALLS
}
write_move() { # <path> <asset destination>
    # shellcheck disable=SC2016  # ${RPC_URL...} is written literally into move.sh
    { printf '#!/bin/bash\n# Temporary e2e case (generated by test/e2e/run.sh).\nset -euo pipefail\nRPC_URL="${RPC_URL:-http://127.0.0.1:8545}"\n'
      bridge_calls "${VAULT}" "${OWNER}" "$2" "${ASSET_WEI}"; } >"$1"
    chmod +x "$1"
}
write_move "${CASE_DIR}/move.sh" "${DEST}"

# Negative: a non-owner cannot make the vault call anything (revert), and nothing moves.
expect_fail "non-owner execute reverts" \
    cast send --unlocked --from "${ATTACKER}" "${VAULT}" "execute(address,uint256,bytes)" "${ATTACKER}" 1 0x --rpc-url "${RPC_URL}"
[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "${vault_wei}" ] || fail "vault changed after a failed non-owner execute"

"${repo_root}/recovery-tx/run.sh" "${CASE_DIR}/move.sh" >"${WORKDIR}/move.out"
TX_HASHES="$(jq -r '.transactionHash // empty' "${WORKDIR}/move.out" 2>/dev/null)"
[ "$(printf '%s\n' "${TX_HASHES}" | grep -cE '^0x[0-9a-fA-F]{64}$')" = "2" ] || { cat "${WORKDIR}/move.out" >&2; fail "expected 2 tx hashes from move.sh"; }
echo "  txs $(printf '%s ' "${TX_HASHES}" | tr '\n' ' ')"

[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "$((vault_wei - ASSET_WEI))" ] || fail "the vault did not lose ${ASSET_WEI} wei"
[ "$(balance_wei "${BRIDGE}" "${RPC_URL}")" = "${ASSET_WEI}" ] || fail "the bridge did not receive ${ASSET_WEI} wei"

# recovery.json from the BridgeEvents (on this fork). The signatures (step 6) are bound to it and to
# move.sh, so both are final from here on.
# shellcheck disable=SC2086  # plain tx hashes
"${repo_root}/recovery-tx/build-recovery.sh" ${TX_HASHES} >"${CASE_DIR}/recovery.json" 2>"${WORKDIR}/build.out" \
    || { cat "${WORKDIR}/build.out" >&2; fail "build-recovery.sh failed"; }
"${repo_root}/recovery-tx/validate-recovery.sh" "${CASE_DIR}/recovery.json" >/dev/null
cs() { cast to-check-sum-address "$1"; }
jq -e --arg v "$(cs "${VAULT}")" --arg d "$(cs "${DEST}")" --arg amount "${ASSET_WEI}" \
    --argjson mn "${MESSAGE_NETWORK}" --arg md "${MESSAGE_METADATA}" '
    .version == 1 and (.outputs | length) == 2
    and .outputs[0] == {leaf_type: 0, token_info: {origin_network: 0, origin_token_address: "0x0000000000000000000000000000000000000000"},
        destination_network: 0, destination_address: $d, amount: $amount, metadata: "0x", deposit_count: 0}
    and .outputs[1] == {leaf_type: 1, token_info: {origin_network: 1, origin_token_address: $v},
        destination_network: $mn, destination_address: $d, amount: "0", metadata: $md, deposit_count: 1}' "${CASE_DIR}/recovery.json" >/dev/null \
    || { cat "${CASE_DIR}/recovery.json" >&2; fail "unexpected recovery.json"; }
# recovery.json format checks (offline): each broken file must be refused with its reason.
bad_recovery() { # <description> <jq filter> <expected message>
    jq "$2" "${CASE_DIR}/recovery.json" >"${WORKDIR}/bad.json"
    expect_fail "validate-recovery rejects $1" "${repo_root}/recovery-tx/validate-recovery.sh" "${WORKDIR}/bad.json"
    grep -qF "$3" "${WORKDIR}/neg.out" || { cat "${WORKDIR}/neg.out" >&2; fail "expected '$3'"; }
}
bad_recovery "another version" '.version = 2' "version: must be 1"
bad_recovery "no outputs" '.outputs = []' "outputs: required"
bad_recovery "an unknown top-level field" '.x = 1' "unknown field: x"
bad_recovery "an unknown output field" '.outputs[0].locked_contract = "0x"' "outputs[0]: unknown field: locked_contract"
bad_recovery "a missing field" 'del(.outputs[1].deposit_count)' "outputs[1]: missing field: deposit_count"
bad_recovery "an unknown leaf type" '.outputs[0].leaf_type = 2' "leaf_type: must be 0"
bad_recovery "a bridgeAsset to another network" '.outputs[0].destination_network = 5' "must be 0 (Ethereum)"
bad_recovery "a numeric amount" '.outputs[0].amount = 5' "amount: must be an integer"
bad_recovery "a bad address" '.outputs[0].destination_address = "0x12"' "destination_address: must be an address"
bad_recovery "no token_info" 'del(.outputs[0].token_info)' "outputs[0]: missing field: token_info"
bad_recovery "token_info not an object" '.outputs[0].token_info = 0' "outputs[0].token_info: must be an object"
bad_recovery "a missing token_info field" 'del(.outputs[0].token_info.origin_token_address)' "outputs[0].token_info: missing field: origin_token_address"
bad_recovery "an unknown token_info field" '.outputs[0].token_info.origin_address = "0x"' "outputs[0].token_info: unknown field: origin_address"
bad_recovery "a bad origin_token_address" '.outputs[1].token_info.origin_token_address = "0x12"' "outputs[1].token_info.origin_token_address: must be an address"
bad_recovery "an origin_network over uint32" '.outputs[0].token_info.origin_network = 4294967296' "outputs[0].token_info.origin_network: must be a uint32"
bad_recovery "the origin fields at the top of the output" '.outputs[0] += .outputs[0].token_info' "outputs[0]: unknown field: origin_network"
bad_recovery "odd-length metadata" '.outputs[1].metadata = "0xabc"' "metadata: must be hex bytes"
bad_recovery "a network over uint32" '.outputs[1].destination_network = 4294967296' "destination_network: must be a uint32"
echo "  recovery.json format checks ok"
echo "  recovery.json: a bridgeAsset of ${ASSET_WEI} wei and a bridgeMessage, both from the vault"

# ---------------------------------------------------------------- 6. sign
step "6. Sign with the owner (throwaway keystore)"
mkdir -p "${KS_DIR}"
# Public anvil test keys only (never real keys).
cast wallet import owner --private-key "${OWNER_TEST_KEY}" --unsafe-password pw --keystore-dir "${KS_DIR}" >/dev/null
cast wallet import dest --private-key "${DEST_TEST_KEY}" --unsafe-password pw --keystore-dir "${KS_DIR}" >/dev/null
cast wallet import attacker --private-key "${ATTACKER_TEST_KEY}" --unsafe-password pw --keystore-dir "${KS_DIR}" >/dev/null
SIGS="${CASE_DIR}/signatures.json"

# Negative: only the destination signed (it is not a sender: an extra, valid signature) -> the owner
# (a sender) is missing.
ADDRESS="${DEST}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${SIGS}" \
    --keystore "${KS_DIR}/dest" --password pw >/dev/null
# shellcheck disable=SC2086  # plain tx hashes
expect_fail "list-impersonated fails without the owner's signature" \
    "${repo_root}/recovery-tx/list-impersonated.sh" --signatures "${SIGS}" ${TX_HASHES}
grep -qi "MISSING signature for ${OWNER}" "${WORKDIR}/neg.out" || fail "expected MISSING signature message for the owner"

ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${SIGS}" \
    --keystore "${KS_DIR}/owner" --password pw >/dev/null

# Negative: signature signed by the wrong key / raw key flags are rejected.
expect_fail "sign-message rejects --private-key" \
    env ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" - --private-key "${OWNER_TEST_KEY}"

# ---------------------------------------------------------------- 7. verify
step "7. Verify the signatures"
# shellcheck disable=SC2086  # plain tx hashes
"${repo_root}/recovery-tx/list-impersonated.sh" --signatures "${SIGS}" ${TX_HASHES} >"${WORKDIR}/list.out"
grep -qi "${OWNER}" "${WORKDIR}/list.out" || fail "owner not listed as impersonated"
"${repo_root}/ownership-proof/verify-signature.sh" "${SIGS}" >/dev/null
[ "$(jq 'length' "${SIGS}")" = "2" ] || fail "expected 2 signatures"

# Negative: a tampered signature must not verify.
jq '.[0].signature = (.[0].signature[0:-4] + "0000")' "${SIGS}" >"${WORKDIR}/forged.json"
expect_fail "verify-signature rejects a forged signature" \
    "${repo_root}/ownership-proof/verify-signature.sh" "${WORKDIR}/forged.json" "${CASE_DIR}"

# The signed message carries a hash of recovery.json + move.sh: signatures do not survive a change
# of either file, nor reuse in another case.
grep -q "case hash: $("${repo_root}/ownership-proof/case-hash.sh" "${CASE_DIR}")" "${WORKDIR}/forged.json" \
    || fail "the signed message lacks the case hash"
CASE_CHANGED="${WORKDIR}/case-changed"
cp -r "${CASE_DIR}" "${CASE_CHANGED}"
echo "# changed after signing" >>"${CASE_CHANGED}/move.sh"
expect_fail "verify-signature rejects signatures after move.sh changed" \
    "${repo_root}/ownership-proof/verify-signature.sh" "${CASE_CHANGED}/signatures.json"
grep -q "case hash" "${WORKDIR}/neg.out" || fail "expected the case hash message"

# The attack: reuse the owner's signature in a case of one's own (other destination). Signing a
# new entry next to it is refused; a hand-assembled file does not verify.
CASE_REPLAY="${WORKDIR}/case-replay"
cp -r "${CASE_DIR}" "${CASE_REPLAY}"
jq --arg a "$(cast to-check-sum-address "${ATTACKER}")" '.outputs[0].destination_address = $a' "${CASE_DIR}/recovery.json" >"${CASE_REPLAY}/recovery.json"
write_move "${CASE_REPLAY}/move.sh" "${ATTACKER}"
expect_fail "sign-message refuses to add a signature next to ones made for other files" \
    env ADDRESS="${ATTACKER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${CASE_REPLAY}/signatures.json" \
    --keystore "${KS_DIR}/attacker" --password pw
grep -q "different version" "${WORKDIR}/neg.out" || fail "expected the different-version message"
attacker_entry="$(CASE_DIR="${CASE_REPLAY}" ADDRESS="${ATTACKER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" - \
    --keystore "${KS_DIR}/attacker" --password pw)"
jq --argjson a "${attacker_entry}" '[.[] | select((.address | ascii_downcase) == ("'"${OWNER}"'" | ascii_downcase))] + [$a]' "${SIGS}" >"${CASE_REPLAY}/signatures.json"
expect_fail "verify-signature rejects the owner's signature reused in another case" \
    "${repo_root}/ownership-proof/verify-signature.sh" "${CASE_REPLAY}/signatures.json"
grep -q "case hash" "${WORKDIR}/neg.out" || fail "expected the case hash message for the reused signature"

# ---------------------------------------------------------------- 8. prepare-submission.sh
step "8. submission/prepare-submission.sh (it starts its own fork each time)"
# The fork of step 4 is used (the bridge calls of step 5 happened on it), so stop it: the scripts
# start a fresh one from geth on the same port, every run.
kill "${fork_pid}" 2>/dev/null || true
docker rm -f "${ANVIL_NAME}" >/dev/null 2>&1 || true
wait "${fork_pid}" 2>/dev/null || true
fork_pid=""

OUT_DIR="${WORKDIR}/out"
# The scripts start the fork themselves with setup/fork.sh: tell it to fork the geth chain.
fork_env() { # BRIDGE_ADDRESS (the mock) is exported above
    L2_RPC_URL="${GETH_URL}" ANVIL_PORT="${ANVIL_PORT}" FORK_BLOCK="${STABLE_BLOCK}" BLOCK_TIME=1 \
        RPC_URL="${RPC_URL}" FORK_LOG="${FORK_LOG}" "$@"
}
pkg() { # <case dir> [extra args] — non-interactive (no TTY)
    local dir="$1"
    shift
    fork_env "${repo_root}/submission/prepare-submission.sh" "${dir}" "$@" </dev/null
}

# Negative: a non-standard fork (another L2_RPC_URL, FORK_BLOCK) is refused unless --allow-test-fork.
expect_fail "prepare-submission.sh refuses a non-standard fork without --allow-test-fork" pkg "${CASE_DIR}" --output-dir "${OUT_DIR}"
grep -q "non-standard fork configuration" "${WORKDIR}/neg.out" || fail "expected the non-standard fork message"

# Negative: a recovery.json that differs from what move.sh bridges.
CASE_DIFF="${WORKDIR}/case-diff"
cp -r "${CASE_DIR}" "${CASE_DIFF}"
jq '.outputs[0].amount = "1"' "${CASE_DIR}/recovery.json" >"${CASE_DIFF}/recovery.json"
expect_fail "prepare-submission.sh rejects a recovery.json that differs from what move.sh does" \
    pkg "${CASE_DIFF}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "does not match what move.sh does" "${WORKDIR}/neg.out" || fail "expected the mismatch message"

# Positive (up to the signatures): with no recovery.json, the run writes it from move.sh — the same
# outputs build-recovery.sh gave in step 5 — then stops because nobody signed for these files yet.
CASE_GEN="${WORKDIR}/case-gen"
cp -r "${CASE_DIR}" "${CASE_GEN}"
rm "${CASE_GEN}/recovery.json"
echo '[]' >"${CASE_GEN}/signatures.json"
expect_fail "prepare-submission.sh writes recovery.json, then asks for the signatures" \
    pkg "${CASE_GEN}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -qi "ADDRESS=${OWNER} NONCE=" "${WORKDIR}/neg.out" || fail "expected the sign-message command for the owner"
[ "$(jq -S . "${CASE_GEN}/recovery.json")" = "$(jq -S . "${CASE_DIR}/recovery.json")" ] \
    || { cat "${CASE_GEN}/recovery.json" >&2; fail "the generated recovery.json differs from build-recovery.sh's"; }
echo "  recovery.json generated from move.sh"

# Negative: no signature for the owner (a sender) -> asks for it and fails without a TTY.
CASE_UNSIGNED="${WORKDIR}/case-unsigned"
cp -r "${CASE_DIR}" "${CASE_UNSIGNED}"
jq --arg owner "${OWNER}" '[.[] | select((.address | ascii_downcase) != ($owner | ascii_downcase))]' "${SIGS}" >"${CASE_UNSIGNED}/signatures.json"
expect_fail "prepare-submission.sh fails when the owner has not signed" pkg "${CASE_UNSIGNED}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -qi "ADDRESS=${OWNER} NONCE=${NONCE}" "${WORKDIR}/neg.out" || fail "expected the sign-message command for the owner"

# Negative: a file changed after signing -> the signatures no longer verify.
CASE_EDITED="${WORKDIR}/case-edited"
cp -r "${CASE_DIR}" "${CASE_EDITED}"
echo "# edited after signing" >>"${CASE_EDITED}/move.sh"
expect_fail "prepare-submission.sh fails when move.sh changed after signing" \
    pkg "${CASE_EDITED}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "case hash" "${WORKDIR}/neg.out" || fail "expected the case hash message"

# Negative: a bridgeAsset to another network than Ethereum (0).
CASE_NET="${WORKDIR}/case-net"
cp -r "${CASE_DIR}" "${CASE_NET}"
net_call="$(cast calldata "bridgeAsset(uint32,address,uint256,address,bool,bytes)" 5 "${DEST}" 1 0x0000000000000000000000000000000000000000 true 0x)"
cat >"${CASE_NET}/move.sh" <<NET
#!/bin/bash
set -euo pipefail
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${BRIDGE}" 1 "${net_call}" --json --rpc-url "\${RPC_URL}"
NET
expect_fail "prepare-submission.sh refuses a bridgeAsset to network 5" \
    pkg "${CASE_NET}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "to network 5" "${WORKDIR}/neg.out" || fail "expected the destination-network message"

# Negative: a BridgeEvent the bridge did not back with funds (the mock's fakeBridgeEvent emits an
# ETH bridgeAsset without taking ETH): the balance check must catch it.
CASE_FAKE="${WORKDIR}/case-fake"
cp -r "${CASE_DIR}" "${CASE_FAKE}"
rm "${CASE_FAKE}/recovery.json"
cat >"${CASE_FAKE}/move.sh" <<FAKE
#!/bin/bash
set -euo pipefail
cast send --unlocked --from "${OWNER}" "${BRIDGE}" "fakeBridgeEvent(address,uint256)" "${DEST}" 5 --json --rpc-url "\${RPC_URL}"
FAKE
expect_fail "prepare-submission.sh refuses BridgeEvents the bridge did not back with funds" \
    pkg "${CASE_FAKE}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "the balances do not match" "${WORKDIR}/neg.out" || fail "expected the balance mismatch message"
[ ! -f "${CASE_FAKE}/recovery.json" ] || fail "recovery.json must not be written when the balances do not match"

# Negative: a move.sh that does not call the bridge at all.
CASE_NOBRIDGE="${WORKDIR}/case-nobridge"
cp -r "${CASE_DIR}" "${CASE_NOBRIDGE}"
cat >"${CASE_NOBRIDGE}/move.sh" <<NOBRIDGE
#!/bin/bash
set -euo pipefail
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${DEST}" 1 0x --json --rpc-url "\${RPC_URL}"
NOBRIDGE
expect_fail "prepare-submission.sh refuses a move.sh that does not call the bridge" \
    pkg "${CASE_NOBRIDGE}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "calls the bridge" "${WORKDIR}/neg.out" || fail "expected the no-bridge message"

# Negative: evm_mine with a timestamp (a time warp) is refused by the sandbox's RPC allowlist.
CASE_WARP="${WORKDIR}/case-warp"
cp -r "${CASE_DIR}" "${CASE_WARP}"
{ printf '#!/bin/bash\nset -euo pipefail\n'
  echo "cast rpc evm_mine '{\"timestamp\": 4102444800}' --rpc-url \"\${RPC_URL}\" >/dev/null"
  bridge_calls "${VAULT}" "${OWNER}" "${DEST}" "${ASSET_WEI}"; } >"${CASE_WARP}/move.sh"
expect_fail "prepare-submission.sh refuses a move.sh that warps the clock with evm_mine" \
    pkg "${CASE_WARP}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "evm_mine with parameters" "${WORKDIR}/neg.out" || fail "expected the evm_mine-with-parameters message"

# Negative: a tx from an unsigned sender still pending when move.sh exits (--async) must be
# collected (the pool is flushed before the scan), so its sender is required to sign.
CASE_PENDING="${WORKDIR}/case-pending"
cp -r "${CASE_DIR}" "${CASE_PENDING}"
cat >>"${CASE_PENDING}/move.sh" <<PENDING
cast send --async --unlocked --from "${ATTACKER}" "${ATTACKER}" --value 1 --rpc-url "\${RPC_URL}" >&2
PENDING
expect_fail "prepare-submission.sh collects a tx still pending when move.sh exits" \
    pkg "${CASE_PENDING}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -qi "${ATTACKER}" "${WORKDIR}/neg.out" || fail "expected the pending tx's sender to be required to sign"

# Negative: a move.sh that edits the state directly (anvil_setBalance) instead of sending
# transactions must be refused by the sandbox's RPC allowlist.
CASE_FORGE="${WORKDIR}/case-forge"
cp -r "${CASE_DIR}" "${CASE_FORGE}"
cat >"${CASE_FORGE}/move.sh" <<FORGE
#!/bin/bash
set -euo pipefail
cast rpc anvil_setBalance "${VAULT}" 0x0 --rpc-url "\${RPC_URL}" >/dev/null
cast rpc anvil_setBalance "${DEST}" "$(cast to-hex "${vault_wei}")" --rpc-url "\${RPC_URL}" >/dev/null
cast send --unlocked --from "${DEST}" "${DEST}" --value 0 --json --rpc-url "\${RPC_URL}"
FORGE
expect_fail "prepare-submission.sh refuses a move.sh that edits the state with anvil_setBalance" \
    pkg "${CASE_FORGE}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "not allowed in the sandbox" "${WORKDIR}/neg.out" || fail "expected the sandbox RPC allowlist to refuse anvil_setBalance"

# Positive: the vault withdraws to the owner (an EOA), which then calls the bridge itself. The
# first run writes recovery.json and asks for the owner's signature; signed, it packages.
CASE_EOA="${WORKDIR}/case-eoa"
cp -r "${CASE_DIR}" "${CASE_EOA}"
rm "${CASE_EOA}/recovery.json"
echo '[]' >"${CASE_EOA}/signatures.json"
cat >"${CASE_EOA}/move.sh" <<EOABRIDGE
#!/bin/bash
set -euo pipefail
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${OWNER}" 1000000000000000000 0x --json --rpc-url "\${RPC_URL}"
cast send --unlocked --from "${OWNER}" "${BRIDGE}" "bridgeAsset(uint32,address,uint256,address,bool,bytes)" 0 "${DEST}" 1000000000000000000 0x0000000000000000000000000000000000000000 true 0x --value 1000000000000000000 --json --rpc-url "\${RPC_URL}"
EOABRIDGE
expect_fail "prepare-submission.sh writes recovery.json for the EOA path, then asks for the owner's signature" \
    pkg "${CASE_EOA}" --allow-test-fork --output-dir "${WORKDIR}/out-eoa"
ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${CASE_EOA}/signatures.json" \
    --keystore "${KS_DIR}/owner" --password pw >/dev/null
pkg "${CASE_EOA}" --allow-test-fork --output-dir "${WORKDIR}/out-eoa" >"${WORKDIR}/package-eoa.out" \
    || { cat "${WORKDIR}/package-eoa.out" >&2; fail "packaging the EOA-path case failed"; }
jq -e --arg d "$(cs "${DEST}")" '(.outputs | length) == 1
    and .outputs[0].leaf_type == 0 and .outputs[0].destination_address == $d' \
    "${CASE_EOA}/recovery.json" >/dev/null || { cat "${CASE_EOA}/recovery.json" >&2; fail "unexpected recovery.json for the EOA path"; }
echo "  package ok with the bridge called by an EOA (the vault withdrew to it first)"

# Positive: tokens and a bridgeMessage carrying ETH. The vault approves and bridges 300 of the native
# token (locked in the bridge), bridges 200 of the wrapped token (burned) and sends a message with
# 7 wei. The balance check covers the three kinds: bridge ETH balance, bridge token balance, supply.
CASE_TOKENS="${WORKDIR}/case-tokens"
cp -r "${CASE_DIR}" "${CASE_TOKENS}"
rm "${CASE_TOKENS}/recovery.json"
echo '[]' >"${CASE_TOKENS}/signatures.json"
approve_call="$(cast calldata "approve(address,uint256)" "${BRIDGE}" 300)"
native_call="$(cast calldata "bridgeAsset(uint32,address,uint256,address,bool,bytes)" 0 "${DEST}" 300 "${NATIVE_TOKEN}" true 0x)"
wrapped_call="$(cast calldata "bridgeAsset(uint32,address,uint256,address,bool,bytes)" 0 "${DEST}" 200 "${WRAPPED_TOKEN}" true 0x)"
msg_call="$(cast calldata "bridgeMessage(uint32,address,bool,bytes)" "${MESSAGE_NETWORK}" "${DEST}" true 0x)"
cat >"${CASE_TOKENS}/move.sh" <<TOKENS
#!/bin/bash
set -euo pipefail
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${NATIVE_TOKEN}" 0 "${approve_call}" --json --rpc-url "\${RPC_URL}"
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${BRIDGE}" 0 "${native_call}" --json --rpc-url "\${RPC_URL}"
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${BRIDGE}" 0 "${wrapped_call}" --json --rpc-url "\${RPC_URL}"
cast send --unlocked --from "${OWNER}" "${VAULT}" "execute(address,uint256,bytes)" "${BRIDGE}" 7 "${msg_call}" --json --rpc-url "\${RPC_URL}"
TOKENS
expect_fail "prepare-submission.sh writes recovery.json for the token case, then asks for the owner's signature" \
    pkg "${CASE_TOKENS}" --allow-test-fork --output-dir "${WORKDIR}/out-tokens"
ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${CASE_TOKENS}/signatures.json" \
    --keystore "${KS_DIR}/owner" --password pw >/dev/null
pkg "${CASE_TOKENS}" --allow-test-fork --output-dir "${WORKDIR}/out-tokens" >"${WORKDIR}/package-tokens.out" \
    || { cat "${WORKDIR}/package-tokens.out" >&2; fail "packaging the token case failed"; }
jq -e --arg n "$(cs "${NATIVE_TOKEN}")" --arg l1 "$(cs "${L1_TOKEN}")" --arg v "$(cs "${VAULT}")" '(.outputs | length) == 3
    and (.outputs[0] | .leaf_type == 0 and .token_info == {origin_network: 1, origin_token_address: $n} and .amount == "300")
    and (.outputs[1] | .leaf_type == 0 and .token_info == {origin_network: 0, origin_token_address: $l1} and .amount == "200")
    and (.outputs[2] | .leaf_type == 1 and .token_info.origin_token_address == $v and .amount == "7" and .metadata == "0x")' \
    "${CASE_TOKENS}/recovery.json" >/dev/null || { cat "${CASE_TOKENS}/recovery.json" >&2; fail "unexpected recovery.json for the token case"; }
mkdir -p "${WORKDIR}/unpacked-tokens"
tar -xzf "${WORKDIR}"/out-tokens/case-tokens-*.tgz -C "${WORKDIR}/unpacked-tokens"
jq -e --arg n "$(printf '%s' "${NATIVE_TOKEN}" | tr '[:upper:]' '[:lower:]')" --arg w "$(printf '%s' "${WRAPPED_TOKEN}" | tr '[:upper:]' '[:lower:]')" '
    (.balances | length) == 3
    and any(.balances[]; .token_info.origin_network == 0 and .token_info.origin_token_address == "0x0000000000000000000000000000000000000000"
        and .measured == "bridge_balance" and .bridged == "7")
    and any(.balances[]; .token_info.origin_network == 1 and .measured == "bridge_balance" and .address == $n
        and .bridged == "300" and ((.after | tonumber) - (.before | tonumber)) == 300)
    and any(.balances[]; .token_info.origin_network == 0 and .measured == "total_supply" and .address == $w
        and .bridged == "200" and ((.before | tonumber) - (.after | tonumber)) == 200)' \
    "${WORKDIR}/unpacked-tokens/case-tokens/manifest.json" >/dev/null \
    || { jq '.balances' "${WORKDIR}/unpacked-tokens/case-tokens/manifest.json" >&2; fail "unexpected balances for the token case"; }
PKG_TOKENS="$(ls "${WORKDIR}"/out-tokens/case-tokens-*.tgz)"
echo "  package ok with a native token, a wrapped token and a bridgeMessage carrying ETH"

# Positive: everything signed -> a package.
pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}" >"${WORKDIR}/package.out"
PKG="$(ls "${OUT_DIR}"/case-*.tgz)"
mkdir -p "${WORKDIR}/unpacked"
tar -xzf "${PKG}" -C "${WORKDIR}/unpacked"
PKG_DIR="${WORKDIR}/unpacked/case"
for f in manifest.json recovery.json move.sh signatures.json fork.log run.log; do
    [ -f "${PKG_DIR}/${f}" ] || fail "package lacks ${f}"
done
jq -e --arg nonce "${NONCE}" --arg owner "${OWNER}" --argjson outputs "$(jq -c '.outputs' "${CASE_DIR}/recovery.json")" '
    .test_fork == true and .nonce == $nonce and (.tx_hashes | length) == 2
    and .required_signers == [$owner | ascii_downcase] and .contract_senders == []
    and .outputs == $outputs
    and .balances == [{token_info: {origin_network: 0, origin_token_address: "0x0000000000000000000000000000000000000000"},
        measured: "bridge_balance", address: (.balances[0].address), before: "0", after: "'"${ASSET_WEI}"'",
        bridged: "'"${ASSET_WEI}"'"}]' "${PKG_DIR}/manifest.json" >/dev/null \
    || { cat "${PKG_DIR}/manifest.json" >&2; fail "unexpected manifest.json"; }
# The hashes in the manifest match the packaged files.
for f in recovery.json move.sh signatures.json fork.log run.log; do
    [ "$(jq -r --arg f "${f}" '.files[$f]' "${PKG_DIR}/manifest.json")" = "$(sha256sum "${PKG_DIR}/${f}" | awk '{print $1}')" ] \
        || fail "manifest hash of ${f} does not match"
done
"${repo_root}/ownership-proof/verify-signature.sh" "${PKG_DIR}/signatures.json" >/dev/null
echo "  package ok: $(basename "${PKG}")"

# Negative: something already answers on the fork port (e.g. a fork started by hand): refused.
docker run -d --rm --name "${ANVIL_NAME}" -p "127.0.0.1:${ANVIL_PORT}:8545" --entrypoint anvil \
    "${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:v1.5.1}" --host 0.0.0.0 >/dev/null
wait_rpc "${RPC_URL}" 60 || fail "the stand-in fork did not answer"
expect_fail "prepare-submission.sh refuses to run while something answers on the fork port" \
    pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "something already answers" "${WORKDIR}/neg.out" || fail "expected the 'already answers' message"
docker rm -f "${ANVIL_NAME}" >/dev/null 2>&1

# Positive, with a manual review: VAULT2 bridges its funds, driven by impersonating the CONTRACT that
# owns it. Nobody signs (a contract cannot), and the verifier must not say a plain VERIFIED: exit
# code 3, "MANUAL REVIEW REQUIRED". The run writes recovery.json first, then packages (no EOA to sign).
CASE_CTRL="${WORKDIR}/case-ctrl"
cp -r "${CASE_DIR}" "${CASE_CTRL}"
rm "${CASE_CTRL}/recovery.json"
{ printf '#!/bin/bash\nset -euo pipefail\n'; bridge_calls "${VAULT2}" "${CONTROLLER}" "${DEST}" "${vault2_wei}"; } >"${CASE_CTRL}/move.sh"
echo '[]' >"${CASE_CTRL}/signatures.json"
pkg "${CASE_CTRL}" --allow-test-fork --output-dir "${WORKDIR}/out-ctrl" >"${WORKDIR}/package-ctrl.out" \
    || { cat "${WORKDIR}/package-ctrl.out" >&2; fail "packaging the contract-sender case failed"; }
PKG_CTRL="$(ls "${WORKDIR}"/out-ctrl/case-ctrl-*.tgz)"
tar -xzf "${PKG_CTRL}" -C "${WORKDIR}/unpacked"
jq -e --arg c "${CONTROLLER}" '(.contract_senders | length) == 1 and ((.contract_senders[0] | ascii_downcase) == ($c | ascii_downcase))
    and .required_signers == []' \
    "${WORKDIR}/unpacked/case-ctrl/manifest.json" >/dev/null || fail "unexpected manifest for the contract-sender case"
echo "  package ok with a contract sender (nobody signs)"

# ---------------------------------------------------------------- 9. verify-submission.sh
step "9. submission/verify-submission.sh on the package"
verify() { # <tgz> [extra args] — starts its own fork like pkg
    local f="$1"
    shift
    fork_env "${repo_root}/submission/verify-submission.sh" "${f}" "$@" </dev/null
}
expect_fail "verify-submission refuses a test package without --allow-test-fork" verify "${PKG}"
grep -q "TEST fork" "${WORKDIR}/neg.out" || fail "expected the test-fork message"
verify "${PKG}" --allow-test-fork >"${WORKDIR}/verify.out" || { cat "${WORKDIR}/verify.out" >&2; fail "verification of a good package failed"; }
grep -q "^VERIFIED:" "${WORKDIR}/verify.out" || fail "expected VERIFIED"
echo "  verified: $(basename "${PKG}")"
verify "${PKG_TOKENS}" --allow-test-fork >"${WORKDIR}/verify-tokens.out" || { cat "${WORKDIR}/verify-tokens.out" >&2; fail "verification of the token package failed"; }
grep -q "^VERIFIED:" "${WORKDIR}/verify-tokens.out" || fail "expected VERIFIED for the token package"
echo "  verified: $(basename "${PKG_TOKENS}")"
# Negative: a manifest whose balances lie (hashes fine) does not match a fresh run.
mkdir -p "${WORKDIR}/tamper-bal"
tar -xzf "${PKG_TOKENS}" -C "${WORKDIR}/tamper-bal"
tok_dir="$(ls -d "${WORKDIR}"/tamper-bal/case-tokens)"
jq '.balances[0].after = "1"' "${tok_dir}/manifest.json" >"${WORKDIR}/m.json" && mv "${WORKDIR}/m.json" "${tok_dir}/manifest.json"
tar -czf "${WORKDIR}/tamper-bal.tgz" -C "${WORKDIR}/tamper-bal" case-tokens
expect_fail "verify-submission rejects a manifest whose balances differ from a fresh run" verify "${WORKDIR}/tamper-bal.tgz" --allow-test-fork
grep -q "FAIL balances" "${WORKDIR}/neg.out" || fail "expected the balances mismatch"

# A package whose funds are moved by a contract sender is not a plain VERIFIED: exit code 3.
set +e
verify "${PKG_CTRL}" --allow-test-fork >"${WORKDIR}/verify-ctrl.out" 2>&1
ctrl_rc=$?
set -e
[ "${ctrl_rc}" -eq 3 ] || { cat "${WORKDIR}/verify-ctrl.out" >&2; fail "expected exit code 3 (manual review) for a contract sender, got ${ctrl_rc}"; }
grep -q "MANUAL REVIEW REQUIRED" "${WORKDIR}/verify-ctrl.out" || fail "expected MANUAL REVIEW REQUIRED"
if grep -q "^VERIFIED:" "${WORKDIR}/verify-ctrl.out"; then fail "a contract sender must not give a plain VERIFIED"; fi
echo "  contract sender: automatic checks pass, manual review required (exit 3)"

# Negative: a file changed after packaging (hash mismatch), a manifest that lies about the
# nonce (hashes fine), and a path-traversal entry.
TAMPER="${WORKDIR}/tamper"
mkdir -p "${TAMPER}/a" "${TAMPER}/b" "${TAMPER}/c"
tar -xzf "${PKG}" -C "${TAMPER}/a"
sed -i.bak "s/${ASSET_WEI}/1${ASSET_WEI}/" "${TAMPER}/a/case/recovery.json"
rm -f "${TAMPER}/a/case/recovery.json.bak"
tar -czf "${TAMPER}/hash.tgz" -C "${TAMPER}/a" case
expect_fail "verify-submission rejects a file that differs from the manifest" verify "${TAMPER}/hash.tgz" --allow-test-fork
grep -q "do not match manifest.json" "${WORKDIR}/neg.out" || fail "expected the hash mismatch message"
tar -xzf "${PKG}" -C "${TAMPER}/b"
jq '.nonce = "999"' "${TAMPER}/b/case/manifest.json" >"${TAMPER}/m.json" && mv "${TAMPER}/m.json" "${TAMPER}/b/case/manifest.json"
tar -czf "${TAMPER}/nonce.tgz" -C "${TAMPER}/b" case
expect_fail "verify-submission rejects a manifest that differs from a fresh run" verify "${TAMPER}/nonce.tgz" --allow-test-fork
grep -q "does not match what the case does" "${WORKDIR}/neg.out" || fail "expected the manifest mismatch message"
echo x >"${TAMPER}/c/f"
tar -czf "${TAMPER}/evil.tgz" -C "${TAMPER}/c" --transform 's#^f#case/../evil#' f
expect_fail "verify-submission rejects a path-traversal entry" verify "${TAMPER}/evil.tgz" --allow-test-fork
grep -q "unsafe path" "${WORKDIR}/neg.out" || fail "expected the unsafe path message"

step "E2E PASSED"

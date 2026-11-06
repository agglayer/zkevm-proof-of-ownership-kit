#!/bin/bash
# End-to-end test of the kit against a throwaway geth --dev node (stand-in for the halted
# zkEVM mainnet), using only test keys.
#
# Flow: geth (docker) -> deploy a "locked" Vault + fund it -> head stays fixed -> start
# setup/fork.sh (anvil in docker) with FORK_BLOCK = that head -> run a temporary case
# (move.sh impersonating the Vault owner) with recovery-tx/run.sh -> sign with
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
step "2. Fund the owner and deploy the locked Vault"
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
printf '[profile.default]\nsolc_version = "0.8.24"\nevm_version = "shanghai"\n' >"${WORKDIR}/forge/foundry.toml"
deploy_json="$(cd "${WORKDIR}/forge" && forge create src/Vault.sol:Vault --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}")"
VAULT="$(printf '%s' "${deploy_json}" | jq -r '.deployedTo')"
[[ "${VAULT}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "vault deployment failed"
cast send "${VAULT}" --value "${FUND_AMOUNT}" --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
echo "  vault ${VAULT}, owner ${OWNER}"

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
dest_before="$(balance_wei "${DEST}" "${RPC_URL}")"
# Snapshot of the pristine fork: step 8 reverts to it to run package.sh on a fresh fork.
SNAP_ID="$(cast rpc evm_snapshot --rpc-url "${RPC_URL}" | tr -d '"')"
echo "  fork up, vault funded on the fork"

# ---------------------------------------------------------------- 5. case
step "5. Temporary case: impersonate the owner and withdraw"
mkdir -p "${CASE_DIR}"
cp -r "${repo_root}/cases/_template/." "${CASE_DIR}/"
cat >"${CASE_DIR}/move.sh" <<MOVE
#!/bin/bash
# Temporary e2e case (generated by test/e2e/run.sh).
set -euo pipefail
RPC_URL="\${RPC_URL:-http://127.0.0.1:8545}"
cast rpc anvil_impersonateAccount "${OWNER}" --rpc-url "\${RPC_URL}" >/dev/null
cast send --unlocked --from "${OWNER}" "${VAULT}" "withdraw(address,uint256)" "${DEST}" "${vault_wei}" \\
    --json --rpc-url "\${RPC_URL}"
MOVE
chmod +x "${CASE_DIR}/move.sh"

# Negative: a non-owner cannot withdraw (revert), and nothing moves.
expect_fail "non-owner withdraw reverts" \
    cast send --unlocked --from "${ATTACKER}" "${VAULT}" "withdraw(address,uint256)" "${ATTACKER}" 1 --rpc-url "${RPC_URL}"
[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "${vault_wei}" ] || fail "vault changed after a failed non-owner withdraw"

"${repo_root}/recovery-tx/run.sh" "${CASE_DIR}/move.sh" >"${WORKDIR}/move.out"
TX_HASH="$(jq -r '.transactionHash // empty' "${WORKDIR}/move.out" 2>/dev/null | tail -n 1)"
[[ "${TX_HASH}" =~ ^0x[0-9a-fA-F]{64}$ ]] || { cat "${WORKDIR}/move.out" >&2; fail "no tx hash from move.sh"; }
echo "  tx ${TX_HASH}"

[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "0" ] || fail "vault not empty after the move"
dest_after="$(balance_wei "${DEST}" "${RPC_URL}")"
[[ "${dest_before}" =~ ^[0-9]{1,19}$ && "${dest_after}" =~ ^[0-9]{1,19}$ ]] || fail "unexpected destination balances"
[ "$((dest_after - dest_before))" = "${vault_wei}" ] \
    || fail "destination did not receive ${vault_wei} wei (before ${dest_before}, after ${dest_after})"
echo "  vault is 0, destination received ${vault_wei} wei"

# ---------------------------------------------------------------- 6. sign
step "6. Sign with the owner and the destination (throwaway keystore)"
mkdir -p "${KS_DIR}"
# Public anvil test keys only (never real keys).
cast wallet import owner --private-key "${OWNER_TEST_KEY}" --unsafe-password pw --keystore-dir "${KS_DIR}" >/dev/null
cast wallet import dest --private-key "${DEST_TEST_KEY}" --unsafe-password pw --keystore-dir "${KS_DIR}" >/dev/null
SIGS="${CASE_DIR}/signatures.json"

# Negative: only the destination signed -> the owner (a sender) is missing.
ADDRESS="${DEST}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${SIGS}" \
    --keystore "${KS_DIR}/dest" --password pw >/dev/null
expect_fail "list-impersonated fails without the owner's signature" \
    "${repo_root}/recovery-tx/list-impersonated.sh" --signatures "${SIGS}" "${TX_HASH}"
grep -qi "MISSING signature for ${OWNER}" "${WORKDIR}/neg.out" || fail "expected MISSING signature message for the owner"

ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${SIGS}" \
    --keystore "${KS_DIR}/owner" --password pw >/dev/null

# Negative: signature signed by the wrong key / raw key flags are rejected.
expect_fail "sign-message rejects --private-key" \
    env ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" - --private-key "${OWNER_TEST_KEY}"

# ---------------------------------------------------------------- 7. verify
step "7. Verify the signatures"
"${repo_root}/recovery-tx/list-impersonated.sh" --signatures "${SIGS}" "${TX_HASH}" >"${WORKDIR}/list.out"
grep -qi "${OWNER}" "${WORKDIR}/list.out" || fail "owner not listed as impersonated"
"${repo_root}/ownership-proof/verify-signature.sh" "${SIGS}" >/dev/null
[ "$(jq 'length' "${SIGS}")" = "2" ] || fail "expected 2 signatures"

# Negative: a tampered signature must not verify.
jq '.[0].signature = (.[0].signature[0:-4] + "0000")' "${SIGS}" >"${WORKDIR}/forged.json"
expect_fail "verify-signature rejects a forged signature" \
    "${repo_root}/ownership-proof/verify-signature.sh" "${WORKDIR}/forged.json"

# ---------------------------------------------------------------- 8. package.sh
step "8. submission/package.sh on a fresh fork"
# Back to the pristine fork (the withdraw of step 5 is undone). A snapshot is consumed by
# the revert, so a new one is taken each time.
fresh_fork() {
    cast rpc evm_revert "${SNAP_ID}" --rpc-url "${RPC_URL}" >/dev/null
    SNAP_ID="$(cast rpc evm_snapshot --rpc-url "${RPC_URL}" | tr -d '"')"
}
fresh_fork
[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "${vault_wei}" ] || fail "revert did not restore the vault"

write_recovery() { # <path> <amount>
    jq -n --arg locked "${VAULT}" --arg dest "${DEST}" --arg amount "$2" \
        '{locked_contract: $locked, destination: $dest, funds: [{token: "native", amount: $amount}]}' >"$1"
}
write_recovery "${CASE_DIR}/recovery.json" "${vault_wei}"
OUT_DIR="${WORKDIR}/out"
pkg() { # <case dir> [extra args] — non-interactive (no TTY), against the fork.log of this run
    local dir="$1"
    shift
    RPC_URL="${RPC_URL}" FORK_LOG="${FORK_LOG}" "${repo_root}/submission/package.sh" "${dir}" "$@" </dev/null
}

# Negative: a fork that is not at the halt block is refused unless --allow-test-fork.
expect_fail "package.sh refuses a test fork without --allow-test-fork" pkg "${CASE_DIR}" --output-dir "${OUT_DIR}"
grep -q "not at the halt block" "${WORKDIR}/neg.out" || fail "expected the halt-block message"

# Negative: declaring more than the vault holds is caught before anything runs.
write_recovery "${CASE_DIR}/recovery.json" "$((vault_wei))0"
expect_fail "package.sh rejects a recovery.json declaring more than the vault holds" \
    pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "less than the" "${WORKDIR}/neg.out" || fail "expected the 'less than declared' message"

# Negative: declaring less than what move.sh moves -> the simulation does not match.
write_recovery "${CASE_DIR}/recovery.json" "$((vault_wei - 1))"
expect_fail "package.sh rejects a move that differs from recovery.json" \
    pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "does not match recovery.json" "${WORKDIR}/neg.out" || fail "expected the mismatch message"
fresh_fork

# Negative: no signature for the owner (a sender) -> asks for it and fails without a TTY.
CASE_UNSIGNED="${WORKDIR}/case-unsigned"
cp -r "${CASE_DIR}" "${CASE_UNSIGNED}"
write_recovery "${CASE_UNSIGNED}/recovery.json" "${vault_wei}"
jq --arg owner "${OWNER}" '[.[] | select((.address | ascii_downcase) != ($owner | ascii_downcase))]' "${SIGS}" >"${CASE_UNSIGNED}/signatures.json"
expect_fail "package.sh fails when the owner has not signed" pkg "${CASE_UNSIGNED}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -qi "ADDRESS=${OWNER} NONCE=${NONCE}" "${WORKDIR}/neg.out" || fail "expected the sign-message command for the owner"
fresh_fork

# Positive: everything signed -> a package.
write_recovery "${CASE_DIR}/recovery.json" "${vault_wei}"
pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}" >"${WORKDIR}/package.out"
PKG="$(ls "${OUT_DIR}"/case-*.tgz)"
mkdir -p "${WORKDIR}/unpacked"
tar -xzf "${PKG}" -C "${WORKDIR}/unpacked"
PKG_DIR="${WORKDIR}/unpacked/case"
for f in manifest.json recovery.json move.sh signatures.json fork.log run.log; do
    [ -f "${PKG_DIR}/${f}" ] || fail "package lacks ${f}"
done
[ "$(balance_wei "${VAULT}" "${RPC_URL}")" = "0" ] || fail "vault not empty after package.sh"
jq -e --arg nonce "${NONCE}" --arg dest "${DEST}" --arg locked "${VAULT}" --arg amount "${vault_wei}" '
    .test_fork == true and .nonce == $nonce and (.tx_hashes | length) == 1
    and (.required_signers | length) == 2 and .contract_senders == []
    and (.destination | ascii_downcase) == ($dest | ascii_downcase)
    and .balances[0].amount == $amount and .balances[0].locked_after == "0"' "${PKG_DIR}/manifest.json" >/dev/null \
    || { cat "${PKG_DIR}/manifest.json" >&2; fail "unexpected manifest.json"; }
# The hashes in the manifest match the packaged files.
for f in recovery.json move.sh signatures.json fork.log run.log; do
    [ "$(jq -r --arg f "${f}" '.files[$f]' "${PKG_DIR}/manifest.json")" = "$(sha256sum "${PKG_DIR}/${f}" | awk '{print $1}')" ] \
        || fail "manifest hash of ${f} does not match"
done
"${repo_root}/ownership-proof/verify-signature.sh" "${PKG_DIR}/signatures.json" >/dev/null
echo "  package ok: $(basename "${PKG}")"

# Negative: running it again on the same (now used) fork is refused.
expect_fail "package.sh refuses a fork already used by an earlier run" pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "less than the" "${WORKDIR}/neg.out" || fail "expected the 'fork already used' message"

# Positive: the destination is also the sender (the owner withdraws to itself) and pays gas,
# so its balance gains less than the amount; package.sh adds the gas back and still passes.
fresh_fork
CASE_SELF="${WORKDIR}/case-self"
cp -r "${CASE_DIR}" "${CASE_SELF}"
sed "s/\"withdraw(address,uint256)\" \"${DEST}\"/\"withdraw(address,uint256)\" \"${OWNER}\"/" "${CASE_DIR}/move.sh" >"${CASE_SELF}/move.sh"
grep -q "\"${OWNER}\" \"${vault_wei}\"" "${CASE_SELF}/move.sh" || fail "could not build the self-withdraw move.sh"
jq -n --arg locked "${VAULT}" --arg dest "${OWNER}" --arg amount "${vault_wei}" \
    '{locked_contract: $locked, destination: $dest, funds: [{token: "native", amount: $amount}]}' >"${CASE_SELF}/recovery.json"
pkg "${CASE_SELF}" --allow-test-fork --output-dir "${WORKDIR}/out-self" >"${WORKDIR}/package-self.out"
tar -xzf "${WORKDIR}"/out-self/case-self-*.tgz -C "${WORKDIR}/unpacked"
jq -e '(.required_signers | length) == 1 and (.balances[0].destination_gas_paid | tonumber) > 0' \
    "${WORKDIR}/unpacked/case-self/manifest.json" >/dev/null || fail "unexpected manifest for the self-withdraw case"
echo "  package ok with destination == sender (gas paid added back)"

# --- Extension point (issue #5): when the verifier exists, add its step here, feeding it
# ${PKG}.

step "E2E PASSED"

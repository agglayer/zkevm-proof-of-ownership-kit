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
# The signatures (step 6) are bound to recovery.json and move.sh, so both are final from here on.
write_recovery() { # <path> <amount>
    jq -n --arg locked "${VAULT}" --arg dest "${DEST}" --arg amount "$2" \
        '{locked_contract: $locked, destination: $dest, funds: [{token: "native", amount: $amount}]}' >"$1"
}
write_recovery "${CASE_DIR}/recovery.json" "${vault_wei}"

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
cast wallet import attacker --private-key "${ATTACKER_TEST_KEY}" --unsafe-password pw --keystore-dir "${KS_DIR}" >/dev/null
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
    "${repo_root}/ownership-proof/verify-signature.sh" "${WORKDIR}/forged.json" "${CASE_DIR}"

# The signed message carries the locked contract, the destination and a hash of recovery.json +
# move.sh: signatures do not survive a change of either file, nor reuse in another case.
grep -q "case hash: $("${repo_root}/ownership-proof/case-hash.sh" "${CASE_DIR}")" "${WORKDIR}/forged.json" \
    || fail "the signed message lacks the case hash"
grep -q "locked contract: $(cast to-check-sum-address "${VAULT}") — destination: $(cast to-check-sum-address "${DEST}")" "${WORKDIR}/forged.json" \
    || fail "the signed message lacks the locked contract / destination"
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
jq --arg a "${ATTACKER}" '.destination = $a' "${CASE_DIR}/recovery.json" >"${CASE_REPLAY}/recovery.json"
sed "s/\"withdraw(address,uint256)\" \"${DEST}\"/\"withdraw(address,uint256)\" \"${ATTACKER}\"/" "${CASE_DIR}/move.sh" >"${CASE_REPLAY}/move.sh"
grep -q "\"${ATTACKER}\" \"${vault_wei}\"" "${CASE_REPLAY}/move.sh" || fail "could not build the replay move.sh"
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
# The fork of step 4 is used (the withdraw of step 5 happened on it), so stop it: the scripts
# start a fresh one from geth on the same port, every run.
kill "${fork_pid}" 2>/dev/null || true
docker rm -f "${ANVIL_NAME}" >/dev/null 2>&1 || true
wait "${fork_pid}" 2>/dev/null || true
fork_pid=""

write_recovery "${CASE_DIR}/recovery.json" "${vault_wei}"
OUT_DIR="${WORKDIR}/out"
# The scripts start the fork themselves with setup/fork.sh: tell it to fork the geth chain.
fork_env() {
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

# Negative: declaring more than the vault holds is caught before anything runs.
write_recovery "${CASE_DIR}/recovery.json" "$((vault_wei))0"
expect_fail "prepare-submission.sh rejects a recovery.json declaring more than the vault holds" \
    pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "less than the" "${WORKDIR}/neg.out" || fail "expected the 'less than declared' message"

# Negative: declaring less than what move.sh moves -> the simulation does not match.
write_recovery "${CASE_DIR}/recovery.json" "$((vault_wei - 1))"
expect_fail "prepare-submission.sh rejects a move that differs from recovery.json" \
    pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "does not match recovery.json" "${WORKDIR}/neg.out" || fail "expected the mismatch message"

# Negative: no signature for the owner (a sender) -> asks for it and fails without a TTY.
CASE_UNSIGNED="${WORKDIR}/case-unsigned"
cp -r "${CASE_DIR}" "${CASE_UNSIGNED}"
write_recovery "${CASE_UNSIGNED}/recovery.json" "${vault_wei}"
jq --arg owner "${OWNER}" '[.[] | select((.address | ascii_downcase) != ($owner | ascii_downcase))]' "${SIGS}" >"${CASE_UNSIGNED}/signatures.json"
expect_fail "prepare-submission.sh fails when the owner has not signed" pkg "${CASE_UNSIGNED}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -qi "ADDRESS=${OWNER} NONCE=${NONCE}" "${WORKDIR}/neg.out" || fail "expected the sign-message command for the owner"

# Negative: a file changed after signing -> the signatures no longer verify.
CASE_EDITED="${WORKDIR}/case-edited"
cp -r "${CASE_DIR}" "${CASE_EDITED}"
write_recovery "${CASE_EDITED}/recovery.json" "${vault_wei}"
echo "# edited after signing" >>"${CASE_EDITED}/move.sh"
expect_fail "prepare-submission.sh fails when move.sh changed after signing" \
    pkg "${CASE_EDITED}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "case hash" "${WORKDIR}/neg.out" || fail "expected the case hash message"

# Negative: a tx from an unsigned sender still pending when move.sh exits (--async) must be
# collected (the pool is flushed before the scan), so its sender is required to sign.
CASE_PENDING="${WORKDIR}/case-pending"
cp -r "${CASE_DIR}" "${CASE_PENDING}"
write_recovery "${CASE_PENDING}/recovery.json" "${vault_wei}"
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
write_recovery "${CASE_FORGE}/recovery.json" "${vault_wei}"
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

# Negative: something already answers on the fork port (e.g. a fork started by hand): refused.
docker run -d --rm --name "${ANVIL_NAME}" -p "127.0.0.1:${ANVIL_PORT}:8545" --entrypoint anvil \
    "${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:v1.5.1}" --host 0.0.0.0 >/dev/null
wait_rpc "${RPC_URL}" 60 || fail "the stand-in fork did not answer"
expect_fail "prepare-submission.sh refuses to run while something answers on the fork port" \
    pkg "${CASE_DIR}" --allow-test-fork --output-dir "${OUT_DIR}"
grep -q "something already answers" "${WORKDIR}/neg.out" || fail "expected the 'already answers' message"
docker rm -f "${ANVIL_NAME}" >/dev/null 2>&1

# Positive: the destination is also the sender (the owner withdraws to itself). Gas is free on the
# fork, so its balance gains exactly the amount and no gas is paid (the check still adds any gas back).
CASE_SELF="${WORKDIR}/case-self"
cp -r "${CASE_DIR}" "${CASE_SELF}"
sed "s/\"withdraw(address,uint256)\" \"${DEST}\"/\"withdraw(address,uint256)\" \"${OWNER}\"/" "${CASE_DIR}/move.sh" >"${CASE_SELF}/move.sh"
grep -q "\"${OWNER}\" \"${vault_wei}\"" "${CASE_SELF}/move.sh" || fail "could not build the self-withdraw move.sh"
jq -n --arg locked "${VAULT}" --arg dest "${OWNER}" --arg amount "${vault_wei}" \
    '{locked_contract: $locked, destination: $dest, funds: [{token: "native", amount: $amount}]}' >"${CASE_SELF}/recovery.json"
echo '[]' >"${CASE_SELF}/signatures.json"
ADDRESS="${OWNER}" NONCE="${NONCE}" "${repo_root}/ownership-proof/sign-message.sh" "${CASE_SELF}/signatures.json" \
    --keystore "${KS_DIR}/owner" --password pw >/dev/null
pkg "${CASE_SELF}" --allow-test-fork --output-dir "${WORKDIR}/out-self" >"${WORKDIR}/package-self.out"
tar -xzf "${WORKDIR}"/out-self/case-self-*.tgz -C "${WORKDIR}/unpacked"
jq -e '(.required_signers | length) == 1 and (.balances[0].destination_gas_paid | tonumber) == 0' \
    "${WORKDIR}/unpacked/case-self/manifest.json" >/dev/null || fail "unexpected manifest for the self-withdraw case"
echo "  package ok with destination == sender (gas is free on the fork)"

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

# Negative: a file changed after packaging (hash mismatch), a manifest that lies about the
# nonce (hashes fine), and a path-traversal entry.
TAMPER="${WORKDIR}/tamper"
mkdir -p "${TAMPER}/a" "${TAMPER}/b" "${TAMPER}/c"
tar -xzf "${PKG}" -C "${TAMPER}/a"
sed -i.bak "s/${vault_wei}/1${vault_wei}/" "${TAMPER}/a/case/recovery.json"
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

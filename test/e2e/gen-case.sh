#!/bin/bash
# Generates the data of a test case, with the same steps and test keys as test/e2e/run.sh:
#   1. starts a fresh `geth --dev` in Docker (stand-in for the halted zkEVM mainnet);
#   2. deploys test/e2e/Vault.sol and funds it (owner-only withdraw);
#   3. records the stable head block (geth --dev only mines on txs);
#   4. writes cases/<case-id>/ with move.sh, recovery.json, an empty signatures.json,
#      a keystore (owner + dest, public test keys, password "pw") and env.sh.
#
# It does NOT start the fork, run move.sh or sign anything: that is up to the caller
# (see test/e2e/gen-and-package.sh, or the commands printed at the end). The geth container
# is left running; remove it with: docker rm -f zkevm-kit-e2e-geth-<GETH_PORT>
#
# Reusable by a verifier: it produces a case whose move.sh, recovery.json and signatures.json
# are consistent with each other (the vault holds exactly the declared amount; owner and
# destination keys are in the keystore, so signatures.json can be filled with sign-message.sh).
#
# Requires: docker (daemon running), cast, forge, curl, jq.
#
# Usage (from anywhere): test/e2e/gen-case.sh [case-id] [--force]
#   case-id   directory name under cases/ (default: test)
#   --force   delete cases/<case-id> first if it already exists
#
# Env overrides: GETH_IMAGE (ethereum/client-go:v1.16.7), GETH_PORT (18545),
#   ANVIL_PORT (18546, only written into env.sh), NONCE (424242), FUND_AMOUNT (5ether)
#
# WARNING: the private keys below are the public anvil/hardhat test keys, worthless.
set -euo pipefail

e2e_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${e2e_dir}/../.." && pwd)"

GETH_IMAGE="${GETH_IMAGE:-ethereum/client-go:v1.16.7}"
GETH_PORT="${GETH_PORT:-18545}"
ANVIL_PORT="${ANVIL_PORT:-18546}"
NONCE="${NONCE:-424242}"
FUND_AMOUNT="${FUND_AMOUNT:-5ether}"

case_id="test"
force=0
for arg in "$@"; do
    case "${arg}" in
    --force) force=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Error: unknown option ${arg}" >&2; exit 1 ;;
    *) case_id="${arg}" ;;
    esac
done
[[ "${case_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "Error: invalid case id '${case_id}'." >&2; exit 1; }
[ "${case_id}" != "_template" ] || { echo "Error: refusing to use _template." >&2; exit 1; }

for bin in docker cast forge curl jq; do
    command -v "${bin}" >/dev/null 2>&1 || { echo "Error: missing ${bin}." >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Error: docker daemon not reachable." >&2; exit 1; }

OWNER_TEST_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEST_TEST_KEY="0x0000000000000000000000000000000000000000000000000000000000000001"
ATTACKER_TEST_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
OWNER="$(cast wallet address --private-key "${OWNER_TEST_KEY}")"
DEST="$(cast wallet address --private-key "${DEST_TEST_KEY}")"
ATTACKER="$(cast wallet address --private-key "${ATTACKER_TEST_KEY}")"

case_dir="${repo_root}/cases/${case_id}"
if [ -e "${case_dir}" ]; then
    [ "${force}" = 1 ] || { echo "Error: ${case_dir} already exists (use --force to replace it)." >&2; exit 1; }
    rm -rf "${case_dir}"
fi

GETH_NAME="zkevm-kit-e2e-geth-${GETH_PORT}"
GETH_URL="http://127.0.0.1:${GETH_PORT}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zkevm-kit-gen.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
step() { echo; echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "1. Start geth --dev (${GETH_IMAGE}) on ${GETH_URL}"
docker rm -f "${GETH_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${GETH_NAME}" -p "${GETH_PORT}:8545" "${GETH_IMAGE}" \
    --dev --http --http.addr 0.0.0.0 --http.port 8545 \
    --http.api eth,net,web3 --http.vhosts '*' --http.corsdomain '*' \
    --nodiscover --maxpeers 0 >/dev/null
i=0
until curl -sS -m 2 -X POST "${GETH_URL}" -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | jq -e '.result' >/dev/null 2>&1; do
    i=$((i + 1)); [ "${i}" -lt 60 ] || fail "geth did not answer on ${GETH_URL}"
    sleep 1
done
echo "  chainId $(cast chain-id --rpc-url "${GETH_URL}")"

step "2. Fund the owner and deploy the locked Vault"
dev_acct="$(cast rpc eth_accounts --rpc-url "${GETH_URL}" | jq -r '.[0]')"
[[ "${dev_acct}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "geth dev account not found"
# First tx is --async: a fresh geth --dev answers "indexing in progress" to receipt lookups.
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
VAULT="$(cd "${WORKDIR}/forge" && forge create src/Vault.sol:Vault --root . --broadcast --json \
    --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" | jq -r '.deployedTo')"
[[ "${VAULT}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "vault deployment failed"
cast send "${VAULT}" --value "${FUND_AMOUNT}" --private-key "${OWNER_TEST_KEY}" --rpc-url "${GETH_URL}" >/dev/null
vault_wei="$(cast balance "${VAULT}" --rpc-url "${GETH_URL}")"
echo "  vault ${VAULT} holds ${vault_wei} wei, owner ${OWNER}"

step "3. Record the stable head block"
b1="$(cast block-number --rpc-url "${GETH_URL}")"
sleep 3
STABLE_BLOCK="$(cast block-number --rpc-url "${GETH_URL}")"
[ "${b1}" = "${STABLE_BLOCK}" ] || fail "geth head is still moving (${b1} -> ${STABLE_BLOCK})"
echo "  STABLE_BLOCK=${STABLE_BLOCK}"

step "4. Write cases/${case_id}/"
cp -R "${repo_root}/cases/_template" "${case_dir}"
cat >"${case_dir}/move.sh" <<MOVE
#!/bin/bash
# Test case generated by test/e2e/gen-case.sh: the owner withdraws the whole vault to DEST.
set -euo pipefail
RPC_URL="\${RPC_URL:-http://127.0.0.1:8545}"
cast rpc anvil_impersonateAccount "${OWNER}" --rpc-url "\${RPC_URL}" >/dev/null
cast send --unlocked --from "${OWNER}" "${VAULT}" "withdraw(address,uint256)" "${DEST}" "${vault_wei}" \\
    --json --rpc-url "\${RPC_URL}"
MOVE
chmod +x "${case_dir}/move.sh"
jq -n --arg locked "${VAULT}" --arg dest "${DEST}" --arg amount "${vault_wei}" \
    '{locked_contract: $locked, destination: $dest, funds: [{token: "native", amount: $amount}]}' >"${case_dir}/recovery.json"
echo '[]' >"${case_dir}/signatures.json"
mkdir -p "${case_dir}/keystore"
cast wallet import owner --private-key "${OWNER_TEST_KEY}" --unsafe-password pw --keystore-dir "${case_dir}/keystore" >/dev/null
cast wallet import dest --private-key "${DEST_TEST_KEY}" --unsafe-password pw --keystore-dir "${case_dir}/keystore" >/dev/null
cat >"${case_dir}/env.sh" <<ENV
# source cases/${case_id}/env.sh   (public test keys only; keystore password: pw)
export GETH_PORT=${GETH_PORT} L2_RPC_URL=${GETH_URL} FORK_BLOCK=${STABLE_BLOCK} ANVIL_PORT=${ANVIL_PORT} BLOCK_TIME=1
export RPC_URL=http://127.0.0.1:${ANVIL_PORT} ETH_RPC_URL=http://127.0.0.1:${ANVIL_PORT}
export NONCE=${NONCE} VAULT=${VAULT} OWNER=${OWNER} DEST=${DEST}
ENV
"${repo_root}/recovery-tx/validate-recovery.sh" "${case_dir}/recovery.json"

step "Done: cases/${case_id}/ (geth ${GETH_NAME} left running)"
cat <<NEXT
Next (from ${repo_root}):
  source cases/${case_id}/env.sh
  setup/fork.sh                                    # separate terminal
  ./recovery-tx/run.sh cases/${case_id}/move.sh    # or submission/prepare-submission.sh cases/${case_id} --allow-test-fork --no-fork
  ADDRESS=\$OWNER NONCE=\$NONCE ./ownership-proof/sign-message.sh cases/${case_id}/signatures.json --keystore cases/${case_id}/keystore/owner --password pw
  ADDRESS=\$DEST  NONCE=\$NONCE ./ownership-proof/sign-message.sh cases/${case_id}/signatures.json --keystore cases/${case_id}/keystore/dest  --password pw
NEXT

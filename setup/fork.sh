#!/bin/bash
# Spins up an Anvil shadow-fork of Polygon zkEVM mainnet, pinned to the exact block the
# chain halted at, after confirming that block is indeed the network's latest published
# block (i.e. nothing has been produced since — you are forking the real halt state,
# not an arbitrary block).
#
# Requires: anvil (Foundry toolchain, https://getfoundry.sh), curl, jq.
#
# Env overrides (see .env.example):
#   L2_RPC_URL   L2 JSON-RPC endpoint to fork from (default: public zkEVM mainnet RPC)
#   ANVIL_PORT   Local port Anvil listens on (default: 8545)
#   BLOCK_TIME   Anvil --block-time in seconds (default: 2)
set -euo pipefail

L2_RPC_URL="${L2_RPC_URL:-https://zkevm-rpc.com/}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
BLOCK_TIME="${BLOCK_TIME:-2}"

# This is the network's halt block, not something you should change. It's re-verified
# against the live RPC below on every run — the script refuses to start if it doesn't
# match, rather than silently forking the wrong state.
fork_block=33391890

for bin in anvil curl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' not found in \$PATH." >&2
        [ "$bin" = "anvil" ] && echo "Install the Foundry toolchain from https://getfoundry.sh" >&2
        exit 1
    fi
done

echo "Fetching latest block from ${L2_RPC_URL} ..."
hex_block="$(curl -sS -X POST "${L2_RPC_URL}" \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result')"

if [ -z "${hex_block}" ] || [ "${hex_block}" = "null" ]; then
    echo "Error: could not fetch eth_blockNumber from ${L2_RPC_URL}" >&2
    exit 1
fi

latest_block="$((hex_block))"
echo "Latest published block on the network: ${latest_block} (${hex_block})"

if [ "${fork_block}" -ne "${latest_block}" ]; then
    echo "Error: hardcoded fork_block (${fork_block}) does not match the network's latest block (${latest_block})." >&2
    echo "This usually means the RPC endpoint is stale or wrong — do not proceed without understanding why." >&2
    exit 1
fi

echo "fork_block matches the network's latest block: ${fork_block}"
echo "Starting Anvil shadow-fork on http://127.0.0.1:${ANVIL_PORT} ..."

# Batch mining via --block-time (auto-mine would produce one block per tx), no block gas
# cap so a single block can hold every pending tx, auto-impersonate so any account can
# send txs without a per-tx anvil_impersonateAccount call, and generous fork-backend
# retries/timeout + no internal rate limiting since every cold storage slot is a
# round-trip to the upstream RPC.
exec anvil \
    --fork-url "${L2_RPC_URL}" \
    --fork-block-number "${fork_block}" \
    --port "${ANVIL_PORT}" \
    --block-time "${BLOCK_TIME}" \
    --disable-block-gas-limit \
    --auto-impersonate \
    --retries 10 \
    --fork-retry-backoff 1000 \
    --timeout 120000 \
    --no-rate-limit

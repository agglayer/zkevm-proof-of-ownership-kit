#!/bin/bash
# End-to-end test of recovery-tx/export-delta-exits.sh against a throwaway local anvil (no fork):
# deploys a mock bridge, two mock ERC-20s and a locker holding ETH + tokens, "recovers" them to a
# destination EOA and checks the exported delta exits. Requires anvil, cast, forge, jq, bc.
#
# Usage: recovery-tx/test/test-export-delta-exits.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export_script="${here}/../export-delta-exits.sh"
PORT="${TEST_ANVIL_PORT:-18545}"
export RPC_URL="http://127.0.0.1:${PORT}"
work="$(mktemp -d)"
anvil_pid=""
cleanup() {
    [ -n "$anvil_pid" ] && kill "$anvil_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

for bin in anvil cast forge jq bc; do command -v "$bin" >/dev/null || { echo "'$bin' not found" >&2; exit 1; }; done

failures=0
check() { # check <description> <command...>
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then echo "  ok   $desc"; else echo "  FAIL $desc"; failures=$((failures + 1)); fi
}
fails() { ! "$@"; }

forge build --root "$here" --contracts "$here" --out "$work/out" --cache-path "$work/cache" >/dev/null 2>&1 ||
    { echo "forge build failed" >&2; exit 1; }
bytecode() { jq -r '.bytecode.object' "$work/out/Mocks.sol/$1.json"; }

anvil --port "$PORT" --silent >"$work/anvil.log" 2>&1 &
anvil_pid=$!
for _ in $(seq 1 50); do cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 0.2; done

accounts=($(cast rpc eth_accounts --rpc-url "$RPC_URL" | jq -r '.[]'))
owner="${accounts[0]}"
destination="${accounts[1]}"
other_eoa="${accounts[2]}"
L1_TOKEN="0x00000000000000000000000000000000000000a1"

deploy() { cast send --unlocked --from "$owner" --rpc-url "$RPC_URL" --json "${@:2}" --create "$1" | jq -r '.contractAddress'; }
send() { cast send --unlocked --from "$owner" "$@" --rpc-url "$RPC_URL" --json | jq -r '.transactionHash'; }

bridge="$(deploy "$(bytecode MockBridge)")"
native_token="$(deploy "$(bytecode MockToken)")"   # native to this chain: not registered in the bridge
wrapped_token="$(deploy "$(bytecode MockToken)")"  # a wrapped L1 token
send "$bridge" "setOrigin(address,uint32,address)" "$wrapped_token" 0 "$L1_TOKEN" >/dev/null
locker="$(deploy "$(bytecode Locker)" --value 30ether)"
send "$native_token" "mint(address,uint256)" "$locker" 1000 >/dev/null
send "$wrapped_token" "mint(address,uint256)" "$locker" 500 >/dev/null

# Recovery txs: 20 ETH (> 2^63 wei, checks the arithmetic) + 250 native token; 10 ETH + 150 wrapped;
# 100 more wrapped (merged with the previous 150). tx3 moves nothing.
tx1="$(send "$locker" "withdraw(address,address,uint256,uint256)" "$destination" "$native_token" 250 20ether)"
tx2="$(send "$locker" "withdraw(address,address,uint256,uint256)" "$destination" "$wrapped_token" 150 10ether)"
tx3="$(send "$locker" "withdraw(address,address,uint256,uint256)" "$destination" "$wrapped_token" 0 0)"
tx4="$(send "$locker" "withdraw(address,address,uint256,uint256)" "$destination" "$wrapped_token" 100 0)"

echo "# export, with signatures covering the destination"
printf '[{"address":"%s","message":"m","signature":"0x"}]' "$destination" >"$work/sigs.json"
"$export_script" --bridge "$bridge" --destination "$destination" --out "$work/exits.json" \
    --signatures "$work/sigs.json" "$tx1" "$tx2" "$tx4" >"$work/export.log" 2>&1 || { cat "$work/export.log"; failures=$((failures + 1)); }
exits="$work/exits.json"
check "3 exits (ETH, native token, wrapped token)" jq -e '.bridge_exits | length == 3' "$exits"
check "ETH: 30 ETH to origin network 0 / zero address (needs >64-bit arithmetic)" \
    jq -e '.bridge_exits[] | select(.token_info.origin_token_address == "0x0000000000000000000000000000000000000000") | .amount == "30000000000000000000" and .token_info.origin_network == 0' "$exits"
check "native token: origin is network 1 and the token itself" \
    jq -e --arg t "$(printf '%s' "$native_token" | tr '[:upper:]' '[:lower:]')" '.bridge_exits[] | select(.token_info.origin_token_address == $t) | .token_info.origin_network == 1 and .amount == "250"' "$exits"
check "wrapped token: origin network 0 / L1 token, 100+150 merged" \
    jq -e --arg t "$L1_TOKEN" '.bridge_exits[] | select(.token_info.origin_token_address == $t) | .token_info.origin_network == 0 and .amount == "250"' "$exits"
check "every exit is a Transfer to the destination on network 0, with no metadata" \
    jq -e --arg d "$destination" 'all(.bridge_exits[]; .leaf_type == "Transfer" and .dest_network == 0 and .dest_address == $d and (has("metadata") | not))' "$exits"
check "summary written" jq -e --arg d "$destination" '.destination == $d and (.transactions | length) == 3' "$work/recovery-summary.json"

echo "# failure cases"
check "no funds received -> fails" fails "$export_script" --bridge "$bridge" --destination "$other_eoa" --out "$work/none.json" "$tx1"
check "destination missing from signatures.json -> fails" \
    fails "$export_script" --bridge "$bridge" --destination "$destination" --out "$work/nosig.json" --signatures <(echo '[]') "$tx1"
check "contract destination -> fails" fails "$export_script" --bridge "$bridge" --destination "$locker" --out "$work/c.json" "$tx1"
check "tx moving nothing to the destination alone -> fails" fails "$export_script" --bridge "$bridge" --destination "$destination" --out "$work/z.json" "$tx3"
check "bad tx hash -> fails" fails "$export_script" --bridge "$bridge" --destination "$destination" --out "$work/b.json" 0x1234

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"

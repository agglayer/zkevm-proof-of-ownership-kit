#!/bin/bash
# Validates a case's recovery.json — the list of bridge exits (outputs) a stakeholder recovers,
# generated from the BridgeEvents of move.sh by recovery-tx/build-recovery.sh. Purely offline:
# it checks the file's shape, not the chain (comparing it with the simulated move is the job
# of the packaging/verification steps).
#
# Rules: only the fields below, all required; addresses are 0x + 40 hex; networks and
# deposit_count are uint32; `outputs` has at least one entry.
#
# Fields:
#   version    1
#   outputs[]  one per BridgeEvent, in the order move.sh emitted them, with aggkit's names:
#     { "leaf_type": 0|1 (0 bridgeAsset, 1 bridgeMessage),
#       "token_info": { "origin_network": <uint32>, "origin_token_address": "0x..." },
#       "destination_network": <uint32> (0 for a bridgeAsset), "destination_address": "0x...",
#       "amount": "<base units, as a string>", "metadata": "0x<hex bytes>",
#       "deposit_count": <uint32> }
#
# Requires: jq.
#
# Usage:
#   recovery-tx/validate-recovery.sh cases/<case-id>/recovery.json
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path/to/recovery.json>" >&2
    exit 1
fi
recovery_path="$1"

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' not found in \$PATH." >&2
    exit 1
fi
if [ ! -f "${recovery_path}" ]; then
    echo "Error: ${recovery_path} not found." >&2
    exit 1
fi
if ! jq -e . "${recovery_path}" >/dev/null 2>&1; then
    echo "Error: ${recovery_path} is not valid JSON." >&2
    exit 1
fi

errors="$(jq -r '
  def addr: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  def uint32: type == "number" and . == floor and . >= 0 and . <= 4294967295;
  ["leaf_type", "token_info", "destination_network", "destination_address",
   "amount", "metadata", "deposit_count"] as $fields
  | ["origin_network", "origin_token_address"] as $token_fields
  | . as $r
  | if type != "object" then "the top level must be a JSON object"
    else
      ( (keys_unsorted - ["version", "outputs"])[] | "unknown field: \(.)" ),
      ( if $r.version != 1 then "version: must be 1" else empty end ),
      ( if ($r.outputs | type) != "array" or ($r.outputs | length) == 0
        then "outputs: required, must be a non-empty list"
        else
          ( $r.outputs | to_entries[] | .key as $i | .value as $o | "outputs[\($i)]" as $w
            | if ($o | type) != "object" then "\($w): must be an object"
              else
                ( ($o | keys_unsorted - $fields)[] | "\($w): unknown field: \(.)" ),
                ( $fields[] as $k | select(($o | has($k)) | not) | "\($w): missing field: \($k)" ),
                ( if $o.leaf_type == 0 or $o.leaf_type == 1 then empty else "\($w).leaf_type: must be 0 (bridgeAsset) or 1 (bridgeMessage)" end ),
                ( if ($o | has("token_info")) | not then empty
                  elif ($o.token_info | type) != "object" then "\($w).token_info: must be an object"
                  else
                    ( ($o.token_info | keys_unsorted - $token_fields)[] | "\($w).token_info: unknown field: \(.)" ),
                    ( $token_fields[] as $k | select(($o.token_info | has($k)) | not) | "\($w).token_info: missing field: \($k)" ),
                    ( if ($o.token_info | has("origin_network") | not) or ($o.token_info.origin_network | uint32) then empty
                      else "\($w).token_info.origin_network: must be a uint32" end ),
                    ( if ($o.token_info | has("origin_token_address") | not) or ($o.token_info.origin_token_address | addr) then empty
                      else "\($w).token_info.origin_token_address: must be an address (0x + 40 hex chars)" end )
                  end ),
                ( ("destination_network", "deposit_count") as $k
                  | if ($o[$k] | uint32) then empty else "\($w).\($k): must be a uint32" end ),
                ( ("destination_address") as $k
                  | if ($o[$k] | addr) then empty else "\($w).\($k): must be an address (0x + 40 hex chars)" end ),
                ( if ($o.amount | type) == "string" and ($o.amount | test("^(0|[1-9][0-9]*)$")) then empty
                  else "\($w).amount: must be an integer in base units, written as a string" end ),
                ( if ($o.metadata | type) == "string" and ($o.metadata | test("^0x([0-9a-fA-F]{2})*$")) then empty
                  else "\($w).metadata: must be hex bytes (0x...)" end ),
                ( if $o.leaf_type == 0 and $o.destination_network != 0 then "\($w).destination_network: must be 0 (Ethereum) for a bridgeAsset" else empty end )
              end )
        end )
    end
' "${recovery_path}")"

if [ -n "${errors}" ]; then
    echo "Error: ${recovery_path} is not valid:" >&2
    printf '%s\n' "${errors}" | sed 's/^/  - /' >&2
    exit 1
fi

echo "OK: ${recovery_path} — $(jq -r '[.outputs[] | select(.leaf_type == 0)] | length' "${recovery_path}") bridgeAsset and $(jq -r '[.outputs[] | select(.leaf_type == 1)] | length' "${recovery_path}") bridgeMessage output(s)"

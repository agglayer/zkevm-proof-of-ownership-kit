#!/bin/bash
# Validates a case's recovery.json — the list of bridge exits (outputs) a stakeholder recovers,
# generated from the BridgeEvents of move.sh by recovery-tx/build-recovery.sh. Purely offline:
# it checks the file's shape, not the chain (comparing it with the simulated move is the job
# of the packaging/verification steps).
#
# Rules: only the fields below, all required; addresses are 0x + 40 hex; networks are uint32;
# `outputs` has at least one entry; per token, `origin_SC_funds` totals what the outputs bridge.
#
# Fields:
#   version    1
#   outputs[]  one per BridgeEvent, in the order move.sh emitted them, with aggkit's names:
#     { "leaf_type": "Transfer" (bridgeAsset) | "Message" (bridgeMessage),
#       "token_info": { "origin_network": <uint32>, "origin_token_address": "0x..." },
#       "destination_network": <uint32> (0 for a Transfer), "destination_address": "0x...",
#       "amount": "<base units, as a string>", "metadata": "0x<hex bytes>" }
#   origin_SC_funds[]  the contracts that held the funds before move.sh, each once:
#     { "address": "0x...",
#       "tokens": [ { "token_info": { "origin_network": <uint32>, "origin_token_address": "0x..." },
#                     "amount": "<total base units it bridged out, as a string>" } ] }
#     Each token at most once per contract. Per token, the amounts over all contracts must add up
#     to the outputs' amounts: a Transfer bridges its token_info, a Message ETH (0 / 0x0...0).
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
  def bigadd($a; $b):
    ($a | explode | reverse | map(. - 48)) as $x | ($b | explode | reverse | map(. - 48)) as $y
    | reduce range(0; [($x | length), ($y | length)] | max) as $i ({c: 0, d: []};
        (($x[$i] // 0) + ($y[$i] // 0) + .c) as $t | .d += [$t % 10] | .c = (($t - $t % 10) / 10))
    | (if .c > 0 then .d + [.c] else .d end) | reverse | map(. + 48) | implode;
  def lc_token: {origin_network, origin_token_address: (.origin_token_address | ascii_downcase)};
  def addr: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  def uint32: type == "number" and . == floor and . >= 0 and . <= 4294967295;
  ["leaf_type", "token_info", "destination_network", "destination_address",
   "amount", "metadata"] as $fields
  | ["origin_network", "origin_token_address"] as $token_fields
  | . as $r
  | if type != "object" then "the top level must be a JSON object"
    else
      ( (keys_unsorted - ["version", "outputs", "origin_SC_funds"])[] | "unknown field: \(.)" ),
      ( if $r.version != 1 then "version: must be 1" else empty end ),
      ( if ($r.outputs | type) != "array" or ($r.outputs | length) == 0
        then "outputs: required, must be a non-empty list"
        else
          ( $r.outputs | to_entries[] | .key as $i | .value as $o | "outputs[\($i)]" as $w
            | if ($o | type) != "object" then "\($w): must be an object"
              else
                ( ($o | keys_unsorted - $fields)[] | "\($w): unknown field: \(.)" ),
                ( $fields[] as $k | select(($o | has($k)) | not) | "\($w): missing field: \($k)" ),
                ( if $o.leaf_type == "Transfer" or $o.leaf_type == "Message" then empty else "\($w).leaf_type: must be \"Transfer\" (bridgeAsset) or \"Message\" (bridgeMessage)" end ),
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
                ( ("destination_network") as $k
                  | if ($o[$k] | uint32) then empty else "\($w).\($k): must be a uint32" end ),
                ( ("destination_address") as $k
                  | if ($o[$k] | addr) then empty else "\($w).\($k): must be an address (0x + 40 hex chars)" end ),
                ( if ($o.amount | type) == "string" and ($o.amount | test("^(0|[1-9][0-9]*)$")) then empty
                  else "\($w).amount: must be an integer in base units, written as a string" end ),
                ( if ($o.metadata | type) == "string" and ($o.metadata | test("^0x([0-9a-fA-F]{2})*$")) then empty
                  else "\($w).metadata: must be hex bytes (0x...)" end ),
                ( if $o.leaf_type == "Transfer" and $o.destination_network != 0 then "\($w).destination_network: must be 0 (Ethereum) for a Transfer" else empty end )
              end )
        end ),
      ( if ($r | has("origin_SC_funds") | not) then "missing field: origin_SC_funds"
        elif ($r.origin_SC_funds | type) != "array" then "origin_SC_funds: must be a list"
        else
          ( [ $r.origin_SC_funds | to_entries[] | .key as $i | .value as $e | "origin_SC_funds[\($i)]" as $w
              | if ($e | type) != "object" then "\($w): must be an object"
                else
                  ( ($e | keys_unsorted - ["address", "tokens"])[] | "\($w): unknown field: \(.)" ),
                  ( if ($e.address | addr) then empty else "\($w).address: must be an address (0x + 40 hex chars)" end ),
                  ( if ($e.tokens | type) != "array" or ($e.tokens | length) == 0 then "\($w).tokens: must be a non-empty list"
                    else
                      ( $e.tokens | to_entries[] | .key as $j | .value as $t | "\($w).tokens[\($j)]" as $u
                        | if ($t | type) != "object" then "\($u): must be an object"
                          else
                            ( ($t | keys_unsorted - ["token_info", "amount"])[] | "\($u): unknown field: \(.)" ),
                            ( if ($t.token_info | type) == "object" and ($t.token_info | keys == ["origin_network", "origin_token_address"])
                                 and ($t.token_info.origin_network | uint32) and ($t.token_info.origin_token_address | addr) then empty
                              else "\($u).token_info: must be {origin_network: <uint32>, origin_token_address: <address>}" end ),
                            ( if ($t.amount | type) == "string" and ($t.amount | test("^[1-9][0-9]*$")) then empty
                              else "\($u).amount: must be a positive integer in base units, written as a string" end )
                          end )
                    end )
                end ] ) as $shape
          | if ($shape | length) > 0 then $shape[]
            else
              ( [ $r.origin_SC_funds[] | .address | ascii_downcase ] | group_by(.)[] | select(length > 1)
                | "origin_SC_funds: \(.[0]) is listed more than once" ),
              ( $r.origin_SC_funds | to_entries[]
                | [ .value.tokens[] | .token_info | lc_token ] as $ts
                | select(($ts | unique | length) != ($ts | length))
                | "origin_SC_funds[\(.key)].tokens: a token is listed more than once" ),
              # Only once the outputs are well-formed: per token, the section totals the outputs.
              ( if ($r.outputs | type) != "array"
                   or any($r.outputs[]; (type != "object") or ((.amount | type) != "string") or ((.amount | test("^(0|[1-9][0-9]*)$")) | not)
                          or (.leaf_type == "Transfer" and (((.token_info | type) != "object")
                              or ((.token_info.origin_token_address | addr) | not)
                              or ((.token_info.origin_network | uint32) | not)))) then empty
                else
                  def totals: group_by(.t) | map({token_info: .[0].t,
                    amount: (reduce .[].a as $a ("0"; bigadd(.; $a)) | sub("^0+(?=.)"; ""))});
                  ( [ $r.outputs[] | select(.amount != "0")
                      | {t: (if .leaf_type == "Transfer" then (.token_info | lc_token)
                             else {origin_network: 0, origin_token_address: "0x0000000000000000000000000000000000000000"} end),
                         a: .amount} ] | totals ) as $want
                  | ( [ $r.origin_SC_funds[].tokens[] | {t: (.token_info | lc_token), a: .amount} ] | totals ) as $got
                  | if $got == $want then empty
                    else "origin_SC_funds: the totals per token do not match the outputs; the outputs bridge \($want | tojson)" end
                end )
            end
        end )
    end
' "${recovery_path}")"

if [ -n "${errors}" ]; then
    echo "Error: ${recovery_path} is not valid:" >&2
    printf '%s\n' "${errors}" | sed 's/^/  - /' >&2
    exit 1
fi

echo "OK: ${recovery_path} — $(jq -r '[.outputs[] | select(.leaf_type == "Transfer")] | length' "${recovery_path}") Transfer (bridgeAsset) and $(jq -r '[.outputs[] | select(.leaf_type == "Message")] | length' "${recovery_path}") Message (bridgeMessage) output(s), from $(jq -r '.origin_SC_funds | length' "${recovery_path}") contract(s)"

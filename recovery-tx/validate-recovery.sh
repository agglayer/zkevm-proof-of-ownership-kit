#!/bin/bash
# Validates a case's recovery.json — the explicit statement of which funds a stakeholder
# wants to recover from which locked Smart Contract, and to which final wallet. Purely
# offline: it checks the file's shape, not the chain (comparing it with the simulated
# move is the job of the packaging/verification steps).
#
# Rules: every field below is required and no others are allowed; addresses are 0x + 40
# hex and neither the zero address nor a template placeholder; `destination` differs from
# `locked_contract`; `funds` has at least one entry, each with a `token` ("native" or an
# ERC-20 address) and an `amount` — a positive integer in base units, written as a string
# so big values are not rounded — and no token appears twice (merge them into one entry).
#
# Fields:
#   locked_contract  the Smart Contract holding the funds
#   destination      the final wallet (EOA) that receives them
#   funds[]          { "token": "native"|"0x...", "amount": "<base units>", "symbol"?: "..." }
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
  def placeholder: type == "string" and (ascii_downcase | . == "0x0000000000000000000000000000000000000000" or . == "0x000000000000000000000000000000000000dead");
  . as $r
  | if type != "object" then "the top level must be a JSON object"
    else
      ( (keys_unsorted - ["locked_contract", "destination", "funds"])[]
        | "unknown field: \(.)" ),
      ( ("locked_contract", "destination") as $k
        | if ($r[$k] | addr | not) then "\($k): must be an address (0x + 40 hex chars)"
          elif ($r[$k] | placeholder) then "\($k): is still a template placeholder (zero address / 0x...dEaD)"
          else empty end ),
      ( if ($r.locked_contract | addr) and ($r.destination | addr)
           and (($r.locked_contract | ascii_downcase) == ($r.destination | ascii_downcase))
        then "destination: must differ from locked_contract" else empty end ),
      ( if ($r.funds | type) != "array" or ($r.funds | length) == 0
        then "funds: required, must be a non-empty list"
        else
          ( $r.funds | to_entries[] | .key as $i | .value as $f
            | if ($f | type) != "object" then "funds[\($i)]: must be an object"
              else
                ( ($f | keys_unsorted - ["token", "amount", "symbol"])[] | "funds[\($i)]: unknown field: \(.)" ),
                ( if $f.token == "native" or ($f.token | addr and (placeholder | not)) then empty
                  else "funds[\($i)].token: must be \"native\" or a token address" end ),
                ( if ($f.amount | type) != "string" then "funds[\($i)].amount: must be a string with the amount in base units (e.g. \"1000000000000000000\")"
                  elif ($f.amount | test("^[1-9][0-9]*$") | not) then "funds[\($i)].amount: must be a positive integer in base units, got \"\($f.amount)\""
                  else empty end ),
                ( if ($f | has("symbol")) and (($f.symbol | type) != "string" or $f.symbol == "") then "funds[\($i)].symbol: must be a non-empty string when present" else empty end )
              end ),
          ( [ $r.funds[] | select(type == "object") | .token | select(type == "string") | ascii_downcase ]
            | group_by(.)[] | select(length > 1) | "funds: token \(.[0]) is listed more than once — merge it into a single entry (sum the amounts)" )
        end )
    end
' "${recovery_path}")"

if [ -n "${errors}" ]; then
    echo "Error: ${recovery_path} is not valid:" >&2
    printf '%s\n' "${errors}" | sed 's/^/  - /' >&2
    exit 1
fi

echo "OK: ${recovery_path} — $(jq -r '.funds | length' "${recovery_path}") fund(s) from $(jq -r '.locked_contract' "${recovery_path}") to $(jq -r '.destination' "${recovery_path}")"

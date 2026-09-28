# AGENTS.md

Single source of truth for agents working in this repo. `CLAUDE.md` imports this file via
`@AGENTS.md`, so Claude Code, Codex, and any other agent that reads `AGENTS.md` share the same
instructions.

---

## Behavioral Guidelines

Behavioral guidelines to reduce common LLM coding mistakes. (Adapted from Andrej Karpathy's
[CLAUDE.md](https://github.com/multica-ai/andrej-karpathy-skills/blob/main/CLAUDE.md).)

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding
**Don't assume. Don't hide confusion. Surface tradeoffs.**
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First
**Minimum code that solves the problem. Nothing speculative.**
- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes
**Touch only what you must. Clean up only your own mess.**
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- Remove imports/variables YOUR changes made unused; leave pre-existing dead code unless asked.

The test: every changed line should trace directly to the request.

### 4. Goal-Driven Execution
**Define success criteria. Loop until verified.**
- "Add validation" → "Write tests for invalid inputs, then make them pass."
- "Fix the bug" → "Write a test that reproduces it, then make it pass."

For multi-step tasks, state a brief plan with a verify step for each item.

---

## Third-Party Tool Docs

The only third-party dependency is the Foundry toolchain (`anvil`, `cast`). Its CLI flags change
between releases, so check `cast <cmd> --help` or the **context7** MCP rather than relying on
training data. If the context7 MCP server is not available, set it up:
https://context7.com/install

---

## Project Overview

Self-service toolkit for stakeholders whose funds are locked in Smart Contracts on the halted
Polygon zkEVM mainnet. A stakeholder runs an Anvil shadow-fork of the halt state, simulates the
transactions that would move their funds to an EOA they control (impersonating whatever addresses
are needed), then proves ownership by signing a fixed message with every EOA involved. Polygon
verifies the submission and, separately, issues an ad-hoc recovery certificate.

The kit **only simulates and proves** — it never moves real funds, never talks to L1, and does not
generate certificates. The end users are often not developers, so user-facing docs must stay
plain and step-by-step.

## Repository Structure

- `setup/` — `fork.sh` starts the Anvil shadow-fork pinned to the halt block; `.env.example` holds
  the optional overrides (`L2_RPC_URL`, `ANVIL_PORT`, `BLOCK_TIME`).
- `recovery-tx/` — `impersonate-and-move.template.sh` (annotated template), `run.sh` (runs a
  case's `move.sh` against the fork), `list-impersonated.sh` (derives senders from receipts and
  verifies a case's `signatures.json`).
- `ownership-proof/` — `message-template.txt` (the fixed proof message), `sign-message.sh`
  (EIP-191 signing via hardware wallet / keystore / hidden prompt, or `--print-message` for
  Etherscan Verified Signatures), and `verify-signature.sh` (verifies every entry of a
  `signatures.json`; the single source of the signature rules, also called by
  `list-impersonated.sh`).
- `cases/` — `_template/` is copied to `cases/<case-id>/` per stakeholder (`README.md`, `move.sh`,
  `signatures.json`).
- `submission/SUBMIT.md` — checklist of what the stakeholder sends back to Polygon.

Fork-state verification lives inside `setup/fork.sh` (it refuses to start unless the RPC's
latest block is the halt block); there is no separate verifier for it.

## Tech Stack

Plain Bash on top of Foundry (`anvil`, `cast`), plus `curl` and `jq`. No Node, Go, or package
manager. Scripts must run on macOS's stock Bash 3.2 as well as Linux Bash 5.

## End-to-End Workflow

All commands run from the **repo root**.

```bash
# 1. Fork (own terminal, leave running)
cd setup && cp .env.example .env && source .env && ./fork.sh

# 2. Start a case and fill in cases/<case-id>/move.sh
cp -r cases/_template cases/<case-id>
./recovery-tx/run.sh cases/<case-id>/move.sh

# 3. Sign — once per EOA sender and once for the destination EOA, same NONCE for the whole case
ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh cases/<case-id>/signatures.json --ledger
#    (or --trezor | --account <name> | --keystore <path> | --interactive)
#    No terminal? ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh --print-message
#    and sign at https://etherscan.io/verifiedSignatures

# 4. Check every sender is covered and every signature is valid
./recovery-tx/list-impersonated.sh --signatures cases/<case-id>/signatures.json <tx-hash> ...
#    (signatures only, no fork needed: ./ownership-proof/verify-signature.sh cases/<case-id>/signatures.json)

# 5. Package per submission/SUBMIT.md
```

## Invariants (do not break)

- **No raw private keys, ever.** `sign-message.sh` delegates to `cast wallet sign` with a signer
  flag and rejects `--private-key*` / `--mnemonic*`. Never add a code path, env var, or doc
  example that puts key material on a command line or in a file.
- **Contracts can't sign.** Ownership of an impersonated contract is proven by signatures from
  the EOA(s) that control it on-chain. `list-impersonated.sh` lists contract senders (non-empty
  `cast code`) separately instead of requiring a signature for them.
- **The proof message is fixed.** `message-template.txt` must stay identical to the copies in
  `README.md` and `cases/_template/README.md`. Changing it invalidates every signature already
  collected, so treat it as a breaking change and ask first.
- **`fork_block=33391890` is the network's halt block.** It is re-verified against the RPC on every
  run; don't change it or relax the check.
- **RPC responses are untrusted input.** Validate them (e.g. regex-check hex quantities) before
  using them in arithmetic or commands — Bash `$(( ))` evaluates variable contents recursively.
- **A signature only counts if it verifies.** `verify-signature.sh` requires `message` to be
  exactly the template filled in with the entry's own address, `cast wallet verify` to recover
  that address from `signature`, one shared nonce per file, and no duplicate addresses. Keep
  these rules in that one script — don't reimplement them elsewhere.

## Conventions

- Commit messages and PR titles follow Conventional Commits (`feat:`, `fix:`, `docs:`, …).
- Every script: `#!/bin/bash`, a header comment (purpose, required env vars, usage),
  `set -euo pipefail`, then the dependency-check loop (`for bin in cast jq; do ... command -v ...`).
- Errors go to stderr and exit non-zero with a message that tells a non-developer what to do next.
- Env vars for configuration (`RPC_URL`, `ADDRESS`, `NONCE`), positional args for paths. Defaults
  use `${VAR:-default}`; `RPC_URL` defaults to `http://127.0.0.1:8545`.
- Every documented command is written relative to the repo root.
- Bash 3.2 compatibility: no `${var,,}` / `${var^^}` (use `tr`), no `mapfile`, no associative
  arrays, and don't expand possibly-empty arrays under `set -u` (use newline-joined strings).
- Keep scripts `shellcheck`-clean.

## Testing

There is no automated test suite or CI. Verify changes with:

```bash
shellcheck $(git ls-files '*.sh')
for f in $(git ls-files '*.sh'); do bash -n "$f"; done
```

Then smoke-test behavior against a **plain local Anvil** (not the mainnet fork, which needs the
upstream RPC):

```bash
anvil --port 8611 --auto-impersonate &
export RPC_URL=http://127.0.0.1:8611 ETH_RPC_URL=http://127.0.0.1:8611
```

- Signing: create a throwaway keystore (`cast wallet import t --private-key <anvil-test-key>
  --unsafe-password pw --keystore-dir /tmp/ks`) and sign with `--keystore /tmp/ks/t --password pw`.
- Contract senders: `cast rpc anvil_setCode <addr> 0x00` + `anvil_setBalance`, then
  `cast send --unlocked --from <addr> ...`.
- Exercise the failure paths too: raw-key flag rejected, wrong `ADDRESS`, empty/forged
  `signatures.json` entries, missing EOA signature.
- `fork.sh` input validation: point `L2_RPC_URL` at a mock server returning a malformed
  `eth_blockNumber` result.

## Common Pitfalls

- `cast` reads `ETH_RPC_URL`, **not** `RPC_URL`. The scripts pass `--rpc-url "${RPC_URL}"`
  explicitly; ad-hoc `cast` calls in tests need `ETH_RPC_URL` or `--rpc-url`, otherwise they
  silently hit `localhost:8545`.
- `fork.sh` refuses to start if the RPC's latest block isn't the halt block — that's intended, not
  a bug to work around.
- `list-impersonated.sh` only sees transaction senders; the destination EOA never sends anything,
  so its signature can't be cross-checked as "required" (it is still verified if present).
- The date in the signed message is the signing day (UTC), so `--print-message` output should be
  signed the same day.

## Maintenance Matrix

|                        When this changes…                       |                                                                    Also update…                                                                   |
| :-------------------------------------------------------------: | :-----------------------------------------------------------------------------------------------------------------------------------------------: |
|              `ownership-proof/message-template.txt`             | `README.md` (Message format), `cases/_template/README.md` example entry, `verify-signature.sh` (assumes placeholder order address → nonce → date) |
|               `sign-message.sh` flags or env vars               |                                       `README.md`, `cases/_template/README.md`, `AGENTS.md` workflow section                                      |
| `list-impersonated.sh` / `verify-signature.sh` checks or output |                                      `cases/_template/README.md` step 4, `submission/SUBMIT.md`, `AGENTS.md`                                      |
|                   `fork.sh` behavior or output                  |                                    `README.md` (Running the shadow-fork), `submission/SUBMIT.md` fork-logs item                                   |
|          `recovery-tx/impersonate-and-move.template.sh`         |                                                   `cases/_template/move.sh` (keep them in sync)                                                   |
|                 Files added/removed/implemented                 |                                                `README.md` layout, `AGENTS.md` Repository Structure                                               |
|                     What stakeholders submit                    |                                             `submission/SUBMIT.md`, `cases/_template/README.md` step 5                                            |

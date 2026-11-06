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

The third-party dependencies are the Foundry toolchain (`anvil`, `cast`) and Docker (`fork.sh` runs
`anvil` from the `ghcr.io/foundry-rs/foundry` image). Foundry's CLI flags change
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
  the optional overrides (`L2_RPC_URL`, `ANVIL_PORT`, `BLOCK_TIME`, `ANVIL_IMAGE`, `FORK_LOG`, test-only `FORK_BLOCK`). `fork.sh`
  also saves its full output to `setup/fork.log`, unmasked: a submission must fork from the official RPC `https://zkevm-rpc.com/`, and `helpers/generate.sh` refuses another `L2_RPC_URL` or a `FORK_BLOCK` unless `--allow-test-fork` (the package is then marked `test_fork`), so the log has no API key.
- `recovery-tx/` — `impersonate-and-move.template.sh` (annotated template), `run.sh` (runs a
  case's `move.sh` against the fork, inside a sandbox container), `validate-recovery.sh` (offline check of a case's
  `recovery.json`), `list-impersonated.sh` (derives senders from receipts and
  verifies a case's `signatures.json`).
- `ownership-proof/` — `message-template.txt` (the fixed proof message, bound to the case: locked
  contract, destination and case hash), `case-hash.sh` (the case hash: sha256 of the sha256 lines of
  `recovery.json` and `move.sh`), `sign-message.sh` (EIP-191 signing via hardware wallet / keystore /
  hidden prompt, or `--print-message` for Etherscan Verified Signatures; fills the message from the
  case's `recovery.json` and `move.sh`), and `verify-signature.sh` (verifies every entry of a
  `signatures.json` against its case directory; the single source of the signature rules, also called
  by `list-impersonated.sh` and `generate.sh`).
- `cases/` — `new-case.sh` copies `_template/` to `cases/<case-id>/` per stakeholder (`README.md`,
  `recovery.json`, `move.sh`, `signatures.json`). `recovery.json` is the explicit claim — locked
  contract, funds (token + amount in base units, as a string) and destination wallet; its schema
  lives in `recovery-tx/validate-recovery.sh`.
- `submission/` — `prepare-submission.sh` is the one script stakeholders run: it pre-checks the case
  (files present, `move.sh` without template placeholders, `recovery.json` valid), runs
  `helpers/generate.sh`, packs its output with `helpers/package.sh` and prints where to send the
  `.tgz` and how to verify it. `helpers/generate.sh` runs a case against the fork and checks it:
  validates `recovery.json`, checks `fork.log`, runs `move.sh`, compares the balances of the locked
  contract and the destination with the declared funds (amounts through `bc`: they are 256-bit),
  derives the senders from the mined blocks, requires a valid signature in the (pre-filled)
  `signatures.json` for every EOA sender plus the destination — it never signs, it prints the
  `sign-message.sh` commands for the missing ones — and writes the files plus `manifest.json` (sha256
  of each file) to an output dir. It starts a fresh fork with `setup/fork.sh` and stops it on exit
  (it refuses to run if something already answers on `RPC_URL`'s port). It is also what a verifier runs to check that `move.sh`,
  `recovery.json` and `signatures.json` fit together. `helpers/package.sh` only packs that output
  into `<case-id>-<timestamp>.tgz`. `verify-submission.sh <tgz>` is the Polygon-side check (also runnable
  by the stakeholder): it unpacks the `.tgz` safely (untrusted: one `<case-id>/` folder, regular files,
  no `..`), checks the manifest sha256s, re-runs the case on a fresh fork through `helpers/generate.sh`
  (recovery.json, impersonated senders, signatures) and compares locked contract, destination, nonce,
  fork block, senders and amounts with `manifest.json` (not tx hashes/gas). The packaged `move.sh`
  runs in the sandbox (see the invariants). `SUBMIT.md` says what the stakeholder sends back to Polygon (the `.tgz`, plus the email) and what is in it.
- `test/e2e/` — end-to-end test (geth `--dev` in Docker + `setup/fork.sh` + a whole case through
  `prepare-submission.sh`), run by `.github/workflows/e2e.yml`.

Fork-state verification lives inside `setup/fork.sh` (it refuses to start unless the RPC's
latest block is the halt block); there is no separate verifier for it.

## Tech Stack

Plain Bash on top of Foundry (`cast`; `anvil` runs in Docker), plus `curl` and `jq`. No Node, Go, or package
manager. Scripts must run on macOS's stock Bash 3.2 as well as Linux Bash 5.

## End-to-End Workflow

All commands run from the **repo root**.

```bash
# 1. (Optional, only to try move.sh by hand) Fork in its own terminal, leave running.
#    prepare-submission.sh (step 5) starts its own fork, so you don't need this for the submission.
cd setup && cp .env.example .env && source .env && ./fork.sh

# 2. Start a case and fill in cases/<case-id>/move.sh
cases/new-case.sh <case-id>
#    fill in cases/<case-id>/recovery.json, then check it:
./recovery-tx/validate-recovery.sh cases/<case-id>/recovery.json
./recovery-tx/run.sh cases/<case-id>/move.sh

# 3. Sign — once per EOA sender and once for the destination EOA, same NONCE for the whole case
ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh cases/<case-id>/signatures.json --ledger
#    (or --trezor | --account <name> | --keystore <path> | --interactive)
#    No terminal? ADDRESS=0x... NONCE=<nonce> ./ownership-proof/sign-message.sh --print-message
#    and sign at https://etherscan.io/verifiedSignatures

# 4. Check every sender is covered and every signature is valid
./recovery-tx/list-impersonated.sh --signatures cases/<case-id>/signatures.json <tx-hash> ...
#    (signatures only, no fork needed: ./ownership-proof/verify-signature.sh cases/<case-id>/signatures.json)

# 5. Package. It starts (and afterwards stops) its own fresh fork — stop the one from step 1 first
#    (it refuses to run while something answers on the port). It repeats steps 2-4
#    itself, fails listing the signatures missing from signatures.json and writes the .tgz to
#    submit, then says where to send it; see submission/SUBMIT.md.
#    Only check (no .tgz): ./submission/helpers/generate.sh cases/<case-id>
./submission/prepare-submission.sh cases/<case-id>
```

## Invariants (do not break)

- **No raw private keys, ever.** `sign-message.sh` delegates to `cast wallet sign` with a signer
  flag and rejects `--private-key*` / `--mnemonic*`. Never add a code path, env var, or doc
  example that puts key material on a command line or in a file.
- **`move.sh` only ever runs in the sandbox.** It is a script written by the submitter and runs
  both when generating a package and when Polygon verifies one, so `recovery-tx/run.sh` runs it in a
  Docker container on a `--internal` network (only the fork's container is attached, as `anvil`), with
  a read-only rootfs, no capabilities, `no-new-privileges`, limits on memory/CPU/pids/time, and only
  `move.sh` mounted (read-only). It reaches the fork only through `recovery-tx/sandbox/rpc-proxy.py`,
  a JSON-RPC allowlist (`eth_*`, `net_*`, `web3_*`, `anvil_impersonateAccount`/`stopImpersonating`,
  `evm_mine`, `txpool_*`): the state cheat codes (`anvil_setBalance`/`setStorageAt`/`setCode`/`reset`,
  `evm_snapshot`...) are refused, otherwise a `move.sh` could fake the balances the checks compare, or
  make the fork fetch a URL. Gas is free on the fork so none is needed. Do not widen the allowlist
  without a security review. Don't add a host-execution path, mount case files or keys into it,
  or pass the environment through. Consequence: `move.sh` must be self-contained and use `${RPC_URL}`. The sandbox image is built from
  `recovery-tx/sandbox/Dockerfile` (Foundry + `jq` + `curl`); keep it minimal.
- **Contracts can't sign.** Ownership of an impersonated contract is proven by signatures from
  the EOA(s) that control it on-chain. `list-impersonated.sh` lists contract senders (non-empty
  `cast code`) separately instead of requiring a signature for them.
- **The proof message is fixed.** `message-template.txt` must stay identical to the copies in
  `README.md` and `cases/_template/README.md` (it carries the locked contract, the destination and the
  case hash, so signatures are bound to a case's `recovery.json` and `move.sh`). Changing it invalidates every signature already
  collected, so treat it as a breaking change and ask first.
- **`halt_block=33391890` is the network's halt block.** `FORK_BLOCK` can override it for tests only (it
  prints a warning, kept in `fork.log`). Either way it is re-verified against the RPC on every
  run; don't change it or relax the check.
- **RPC responses are untrusted input.** Validate them (e.g. regex-check hex quantities) before
  using them in arithmetic or commands — Bash `$(( ))` evaluates variable contents recursively.
- **A signature only counts if it verifies.** `verify-signature.sh` requires `message` to be
  exactly the template filled in with the entry's own address, the case's `locked_contract` and
  `destination` and the case hash of its `recovery.json` + `move.sh` (so a signature cannot be reused
  in another case, nor after a file changed), `cast wallet verify` to recover that address from
  `signature`, one shared nonce per file, and no duplicate addresses. Keep these rules in that one
  script — don't reimplement them elsewhere.

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

`test/e2e/run.sh` is an end-to-end test (needs Docker, `cast`, `forge`) that CI runs on every PR
(`.github/workflows/e2e.yml`); run it after touching any script. Besides it, verify changes with:

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

|                                     When this changes…                                     |                                                                                                           Also update…                                                                                                           |
| :----------------------------------------------------------------------------------------: | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------: |
|                           `ownership-proof/message-template.txt`                           | `README.md` (Message format), `cases/_template/README.md` example entry, `verify-signature.sh` (assumes placeholder order address → locked_contract → destination → case_hash → nonce → date), `case-hash.sh`, `sign-message.sh` |
|                            `sign-message.sh` flags or env vars                             |                                                                              `README.md`, `cases/_template/README.md`, `AGENTS.md` workflow section                                                                              |
|              `list-impersonated.sh` / `verify-signature.sh` checks or output               |                                                                             `cases/_template/README.md` step 3, `submission/SUBMIT.md`, `AGENTS.md`                                                                              |
|                                `fork.sh` behavior or output                                |                                                                           `README.md` (Running the shadow-fork), `submission/SUBMIT.md` fork-logs item                                                                           |
|                       `recovery-tx/impersonate-and-move.template.sh`                       |                                                                                          `cases/_template/move.sh` (keep them in sync)                                                                                           |
|                      `recovery.json` fields (`validate-recovery.sh`)                       |                                                           `cases/_template/recovery.json` and README step 1, `submission/SUBMIT.md`, `AGENTS.md` Repository Structure                                                            |
| `submission/prepare-submission.sh` / `verify-submission.sh` / `helpers/*` checks or output |                                                      `submission/SUBMIT.md` (contents table), `cases/_template/README.md` step 5, `test/e2e/run.sh` steps 8-9, `AGENTS.md`                                                       |
|                              Files added/removed/implemented                               |                                                                                       `README.md` layout, `AGENTS.md` Repository Structure                                                                                       |
|                                  What stakeholders submit                                  |                                                           `submission/SUBMIT.md`, `cases/_template/README.md` step 4, `submission/helpers/` (package layout, manifest)                                                           |

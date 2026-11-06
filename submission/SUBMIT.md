# What to submit

**The `.tgz` that [`submission/prepare-submission.sh cases/<your-case-id>`](prepare-submission.sh)
writes** (`cases/<your-case-id>/<your-case-id>-<timestamp>.tgz`) — nothing else. Check it first
with [`submission/verify-submission.sh`](verify-submission.sh) (see below).

Email it to [`zkevm-claims@polygon.technology`](mailto:zkevm-claims@polygon.technology), with your
case reference (the support thread or case ID this submission relates to) in the subject line. If
`move.sh` impersonates a **contract** (it has no private key, so the EOA(s) that control it sign
instead), also explain in the email how they control it — e.g. which `owner()` / `getOwners()` call
returns them at the fork block. The package lists those contracts in `manifest.json`
(`contract_senders`).

## What is in the package

Laid out as `<case-id>/`:

| File | What it is |
| --- | --- |
| `recovery.json` | What you recover: the locked contract, the funds (token and amount) and the destination wallet. |
| `move.sh` | The simulated recovery that Polygon re-runs on its own fork. |
| `signatures.json` | One signature per EOA impersonated in `move.sh` plus the destination, each over the fixed proof message, which includes the locked contract, the destination, a hash of `recovery.json` and `move.sh`, the nonce and the date: a signature only counts for those exact files. |
| `manifest.json` | What the run found: tx hashes, impersonated addresses, nonce, balances before and after, whether it was a test fork, and the sha256 of every file. |
| `fork.log` | Full output of `setup/fork.sh`, with the halt block and its confirmation line. Informational: the verifier checks its own fork, not this file. |
| `run.log` | Output of `move.sh` on the fork. Informational, like `fork.log` (only its hash is checked). |
| `etherscan-links.txt` | Only if you put one in your case directory: links to signatures published at [etherscan.io/verifiedSignatures](https://etherscan.io/verifiedSignatures) instead of `sign-message.sh`. |

## Verifying a package

```bash
submission/verify-submission.sh <your-case-id>-<timestamp>.tgz
```

On receiving your submission, Polygon first **inspects it manually** (the email, `recovery.json`,
`move.sh` and who has to sign) before running anything. Only then does it run this same
script, which unpacks the `.tgz`, checks the file hashes in `manifest.json`, re-runs `move.sh`
on a fresh fork, checks it against `recovery.json`, derives the impersonated addresses,
verifies every signature and compares all of it with `manifest.json`. The packaged `move.sh`
runs inside a sandbox container that can only reach the fork (no internet, nothing of your
machine), the same one `prepare-submission.sh` uses.

Passing the script is necessary, not sufficient: the manual inspection can still send a
submission back, e.g. when the explanation of how the EOAs control an impersonated contract
is missing or does not hold up.

## Why every signature is mandatory

Impersonation on a shadow-fork proves nothing about real-world control — anyone can
impersonate any address on a fork they run locally. Recovery certificates are only
generated after every required signature is submitted and independently verified.
Incomplete submissions (missing a signer, mismatched nonce/date, wrong message format)
will be sent back for correction before any certificate work begins.

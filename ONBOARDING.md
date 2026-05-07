# Onboarding · peaq-contracts

> Hey. Welcome to the team. This doc is the 60-minute tour of this repo. Read it once, then come back to it as a reference.

We assume you know Solidity, have used Foundry before, and are comfortable on Linux/macOS/Windows-with-WSL. If you don't know peaq, that's fine — we'll explain what's peaq-specific as we go.

---

## TL;DR

This repo holds three Solidity contracts that AXI Mobility deploys on the **peaq** blockchain.

- `InsuranceRiskOracle` — publishes a risk score per vehicle so insurers can read it directly from the chain.
- `HighRiskCommandVault` — multi-person approval gate for fleet-wide actions ("lock 47 bikes" needs 2 of 3 sign-offs).
- `CredentialRevocationRegistry` — anyone can check on-chain whether a driver's licence or inspection certificate is still valid.

Plus the runbooks, threat models, and CI to ship them safely.

The repo's sibling is [`peaq-integration`](https://github.com/aximobility/peaq-integration) — the TypeScript SDK and CLI that talks to these contracts (and to peaq's identity / role / storage pallets). Read that one second.

---

## 60-second repo tour

```
peaq-contracts/
├── src/                       <- the 3 Solidity contracts + interfaces
├── test/                      <- Foundry tests, one .t.sol per contract
├── script/                    <- Deploy + Verify forge scripts
├── threat-models/             <- per-contract STRIDE security analysis
├── broadcast/                 <- forge's deploy artifacts (auto-generated)
├── lib/                       <- vendored deps (forge-std, OZ) via git submodules
├── docs/                      <- LaTeX milestone PDF + branding assets
├── .github/workflows/         <- CI: build, test, fmt, lint
├── foundry.toml               <- compiler + optimizer + remappings
├── Makefile                   <- one command per common task
├── README.md                  <- project front door
├── ONBOARDING.md              <- you are here
├── PEAQ_REVIEW.md             <- partnership review packet for the peaq team
├── MILESTONES.md              <- what we've shipped + what's next
├── AUDIT_CHECKLIST.md         <- pre-audit hardening status (about 80% closed)
├── AGUNG_DEPLOY.md            <- 25-minute deploy walkthrough
├── SECURITY.md                <- responsible disclosure policy
└── LICENSE                    <- Apache-2.0
```

---

## What the three contracts do (and why they exist)

### 1. InsuranceRiskOracle

**The problem.** Kenyan insurers price fleet premiums on patchy data, so they add a 15-25% "uncertainty surcharge" they can't justify. Our pilot customer (ROAM Electric, 10 EV motorcycles) overpays.

**What this contract does.** AXI's signers post a risk score (0-1000) on-chain for each vehicle. The score is append-only and signed. Insurers read `riskScore(vehicleDid)` directly from the chain when quoting. No middleman, no API outage, no trust in AXI's database.

**Why on-chain.** Insurers won't trust AXI's database — we have a financial incentive to lie. They'll trust a public log they can read and audit themselves.

**Key API:**
- `attest(vehicleDid, score, anchorRoot, sampleSizeKm)` — only `ATTESTOR_ROLE` can call.
- `riskScore(vehicleDid) → (score, attestedAt)` — public read; reverts if older than `maxAttestationAgeSeconds`.
- `priceMultiplierBps(vehicleDid)` — turns a score into a premium multiplier (basis points, 10000 = 1.0x).

### 2. HighRiskCommandVault

**The problem.** Fleet-wide actions are dangerous. "Lock 47 bikes" is one click and historically one password. Single-sig escape hatches are how fleet platforms get held ransom.

**What this contract does.** Multi-person approval gate. AXI staff propose a high-risk command (lock the fleet, override every route, withdraw funds). A pre-set group of approvers must sign. Once enough approve (e.g. 2 of 3), anyone can run the command — including a regulator if AXI staff disappear.

**Why on-chain.** A Slack approval can be denied later. An on-chain signed approval cannot. The audit trail is the product — insurers and regulators want proof of governance before pricing premiums or licensing the fleet.

**Why NOT upgradeable.** An upgradeable approval gate is a back door. Operators see the exact rules they're approving, and AXI cannot silently change them later. This is the only contract in the repo that is fixed forever.

**Key API:**
- `propose(commandType, targetDid, payloadHash, K, M, expirySeconds) → commandId`
- `approve(commandId)`
- `execute(commandId, payload)` — permissionless once `K` approvers signed
- `cancel(commandId)` — proposer only
- `markExpired(commandId)` — anyone, after expiry

### 3. CredentialRevocationRegistry

**The problem.** Driver licences, NTSA inspection certificates, and insurance binders all expire or get revoked. Today fleets find out at the roadside check ($300 fine + tow-truck bill). Insurers find out at claim time ($5,000 loss). Verification is paper-based.

**What this contract does.** Each credential has a unique fingerprint stored on-chain. When the issuer (NTSA, insurance, fleet manager) cancels it, they post the cancellation. Anyone — insurer, regulator, the rider app — can instantly check whether a credential is still valid.

**Key API:**
- `revoke(credentialHash, reasonCode)` — `ISSUER_ROLE` only.
- `revokeBatch(credentialHashes[], reasonCode)` — capped at 100 per call (`MAX_BATCH_SIZE`).
- `unrevoke(credentialHash)` — admin-only emergency undo (e.g. compromised issuer key).
- `isRevoked(credentialHash) → bool` — free public read.
- `whyRevoked(credentialHash) → RevocationRecord` — returns reason + revoker + timestamp.

---

## File-by-file walkthrough

### Top-level config

| File | What it does |
|---|---|
| `foundry.toml` | Foundry config. Solidity 0.8.24, optimizer 10000 runs, via-IR enabled, fuzz at 256 runs. **Don't downgrade the optimizer settings** — gas measurements in `.gas-snapshot` assume them. |
| `remappings.txt` | Maps `@openzeppelin/...` and `forge-std/...` to the `lib/` submodules. |
| `foundry.lock` | Pins the Foundry toolchain version so CI and local runs match. |
| `.gitmodules` | Tracks the OpenZeppelin v5 + forge-std submodules under `lib/`. |
| `.gas-snapshot` | Committed gas-cost baseline. CI compares against this; a regression fails the build. |
| `.env.example` | Template for the env vars the deploy script needs. **Never commit `.env`** — it's gitignored. |
| `.gitignore` | Ignores `out/`, `cache/`, `.env`, `node_modules`, LaTeX artifacts. |
| `Makefile` | Single source of truth for common tasks. Run `make help` (or read the file) — every target maps to one Foundry command. |
| `LICENSE` | Apache-2.0. Permissive, commercial-friendly. Anyone can use, modify, redistribute. |

### `src/` — the contracts

| File | What it does |
|---|---|
| `InsuranceRiskOracle.sol` | UUPS proxy + AccessControl + Pausable. Append-only score history per `vehicleDid`. Linear-interpolation premium multiplier between a configurable `floorBps` and `ceilingBps`. Admin can recalibrate the curve and adjust the staleness window. |
| `HighRiskCommandVault.sol` | **Not upgradeable.** AccessControl + ReentrancyGuard + Pausable. State machine: `Proposed → Approved → Executed`. `Cancelled` and `Expired` are also terminal. `commandId` derivation includes `block.timestamp + msg.sender` to make replay safe. |
| `CredentialRevocationRegistry.sol` | UUPS proxy + AccessControl + Pausable. Append-only revocation map. `revokeBatch` is capped at `MAX_BATCH_SIZE = 100` to prevent gas-bomb DoS via a compromised issuer key. |

### `src/interfaces/` — separated interfaces

Every contract has its public surface (events, errors, structs, function signatures) declared in a separate `I<Name>.sol` file. The implementation imports the interface and uses `override` on each public function.

**Why separated.** Three reasons:
1. SDK clients (in `peaq-integration`) consume just the interface, not the implementation. Smaller bytecode footprint, cleaner ABI export.
2. UUPS upgrades let us change the implementation. The interface is the stable contract with consumers.
3. Custom errors live at the interface level so external callers can decode them without the implementation source.

### `test/` — Foundry tests

| File | What it does |
|---|---|
| `CredentialRevocationRegistry.t.sol` | 16 tests: happy paths, reverts, role-gating, batch limits, idempotency. |
| `HighRiskCommandVault.t.sol` | 18 tests: state-machine paths, replay-safety, K-of-M counting, executor permissionlessness, pause behaviour. |
| `InsuranceRiskOracle.t.sol` | 17 tests including 4 fuzz suites (256 runs each): score range, multiplier monotonicity, staleness gate, recalibration. |

**51 tests total. They all pass.** Run `forge test` locally before any commit.

Patterns we use everywhere:
- `vm.expectEmit(true, true, true, true)` before each event-emitting call.
- One `Reject*` test per custom error.
- Fuzz with `bound()` to keep inputs in valid ranges.
- `vm.startPrank(addr)` / `vm.stopPrank()` for role-based tests.

### `script/` — Foundry deploy scripts

| File | What it does |
|---|---|
| `Deploy.s.sol` | Deploys all three contracts (impl + UUPS proxy for Oracle and Registry; Vault directly). Reads admin + initial role lists from env vars. |
| `Verify.s.sol` | Verifies bytecode + initial state on a target chain after deploy. |

**Heads-up.** `broadcast/Deploy.s.sol/9990/run-latest.json` is currently a **local Anvil fork run** (deployer is the Anvil default `0xf39fd6...`). A real Agung deploy with a funded EOA is the next step before mainnet. We say so plainly in `PEAQ_REVIEW.md` and the milestone PDF.

### `threat-models/` — STRIDE security analysis

One STRIDE doc per contract. Each lists the threat surface (Spoofing / Tampering / Repudiation / Info disclosure / DoS / Elevation), the mitigation, a DREAD score, and the invariants we want an external audit firm to formally verify.

These are required pre-audit reading. If you change a contract, update its threat model in the same PR.

### `docs/`

| Folder | What it holds |
|---|---|
| `docs/branding/` | The AXI x peaq logo lockup used in the milestone PDF and root README banner. |
| `docs/latex/` | The LaTeX source + rendered PDF of the milestone walkthrough we send to peaq's tech team. Compile with `lualatex AXI_peaq_Milestone_Update.tex` (run twice for TOC). |

### `.github/workflows/ci.yml`

Runs on every push and PR:
1. `forge fmt --check` — code style.
2. `forge build` — must compile.
3. `forge test` — all 51 tests must pass.
4. `forge snapshot --diff` — gas regressions fail the build.
5. Slither (advisory only — `continue-on-error: true` for now; will be hard-gated post-audit).

### Other top-level docs

| File | What it is |
|---|---|
| `README.md` | The project front door. Plain-language overview for someone who lands on the GitHub page. |
| `PEAQ_REVIEW.md` | Partnership-facing technical review packet for peaq's tech team. 13 sections: architecture, contracts, deploy status, threat surface, asks. |
| `MILESTONES.md` | What we've shipped, when, and what's next. The Markdown twin of the LaTeX milestone PDF. |
| `AUDIT_CHECKLIST.md` | Pre-audit hardening status, about 80% complete. Auditor reads this first. |
| `AGUNG_DEPLOY.md` | 25-minute zero-to-first-attestation deploy walkthrough. |
| `SECURITY.md` | Responsible disclosure policy. Where to send vuln reports + bounty terms. |

---

## Why we made the decisions we did

### Why peaq, not Ethereum / Polygon / Arbitrum

peaq ships three things we'd otherwise have to build and maintain ourselves:

1. **`peaqDid` pallet** — built-in identity registry. Generic L1s force you to write your own DID method + registry contract.
2. **`peaqRbac` pallet** — built-in role system. Generic L1s force you to write a permissions contract.
3. **`peaqStorage` pallet** — built-in evidence storage. Generic L1s force you to pick one model or run two chains.

Plus peaq is mobility-native (DePIN focus) — the ecosystem peers are ROAM-class, not generic DeFi.

We post a daily Merkle anchor to **Polygon mainnet** as a fallback in case peaq has an outage. Polygon is redundancy, not primary. peaq is the chain.

### Why UUPS for Oracle + Registry, but NOT for Vault

**Oracle and Registry need to evolve.** We'll add features (per-issuer scope, dispute mechanism, finer score granularity) over time. UUPS lets us upgrade without breaking integrators.

**Vault must NOT evolve.** It's an approval gate. If AXI can change the rules silently, the gate is a security theatre. So Vault is fixed forever — bytecode is what operators reviewed and signed up to. If we want a new gate later, we deploy a new contract with a new address; consumers explicitly migrate.

**Storage gap reserves.** Both UUPS contracts have `__gap[N]` arrays at the end. This reserves storage slots so future upgrades can add state variables without colliding with parent-contract slots. Standard OpenZeppelin v5 pattern.

### Why role-based access (and NOT per-issuer scope on Registry, today)

The Registry uses `ISSUER_ROLE` — any address with that role can revoke any credential. The on-chain `revokedBy` field records who did it.

**Why not per-credential issuer scope yet.** It's a structural change (track issuer at registration time, restrict revoke to that issuer). We'll ship it as a Phase-5 enhancement once the audit lands. Adding it under time pressure risks a real security bug. We'd rather be honest in the docs than fake the scope.

### Why custom errors instead of `require` strings

Custom errors cost less gas to revert with, and they let the SDK match exact failure modes via `decodeErrorResult`. `require("not authorized")` is lazy and unscoped. We don't use `require` strings anywhere.

### Why Foundry over Hardhat

- Solidity-native test DSL (no JS context-switching).
- Fuzzing is built-in.
- 10x faster on a cold cache.
- Forge scripts beat Hardhat tasks for deploys.

### Why `MAX_BATCH_SIZE = 100` on Registry

A compromised `ISSUER_ROLE` key could submit a single jumbo `revokeBatch` call to grief the chain. 100 is well below any reasonable gas limit and gives operators room to rotate keys + sweep batches over multiple blocks. The cap is enforced **on-chain** via `BatchTooLarge` — not just documented.

### Why local Anvil fork before real Agung

We exercise the full deploy script + initial state seeding against a fork of Agung in CI. That catches typos in the script, bad role assignments, and gas surprises before we burn real testnet tokens. The artifact in `broadcast/.../9990/run-latest.json` is that fork run. A real Agung deploy with a funded EOA is the next milestone.

### Why Apache-2.0

Permissive, commercial-friendly, well-understood. The contracts have no novel cryptography or trade secrets — public review (Linus's Law) helps us catch bugs faster than secrecy ever would. Donny + JP from peaq's tech team review this code anyway.

### Why STRIDE per contract (not one global threat model)

Each contract has different attack surface, different roles, different invariants. A global threat model collapses meaningful distinctions. Per-contract STRIDE is what audit firms expect to receive — they can read straight from our doc into their report template.

---

## How to run things

### One-time setup

```bash
git clone git@github.com:aximobility/peaq-contracts.git
cd peaq-contracts
make install            # installs Foundry deps via submodules
cp .env.example .env    # then fill in PRIVATE_KEY, RPC_URL, etc.
```

### Daily loop

```bash
make build              # forge build
make test               # forge test (51 tests)
make fmt                # forge fmt
make snapshot           # update .gas-snapshot
make slither            # local security scan (advisory)
```

### Before opening a PR

```bash
make test               # green
make fmt                # no diff
make snapshot           # no unintended gas regressions
```

### Deploy to Agung (real, when funded)

```bash
make deploy-agung       # see AGUNG_DEPLOY.md for the full walkthrough
make verify-agung       # post-deploy state verification
```

---

## Where to look for what

| You want to... | Read |
|---|---|
| Understand a contract's API | `src/interfaces/I<Name>.sol` |
| See an actual scenario | `MILESTONES.md` § 2 (Mary Akinyi, Wanjiku NTSA, etc.) |
| Run the deploy | `AGUNG_DEPLOY.md` |
| Add a feature | `src/<Name>.sol` + matching `test/<Name>.t.sol` + update `threat-models/<Name>.STRIDE.md` |
| Audit the security model | `threat-models/` |
| Send something to peaq's team | `PEAQ_REVIEW.md` + `docs/latex/AXI_peaq_Milestone_Update.pdf` |
| Report a vuln | `SECURITY.md` |
| Track what's left | `AUDIT_CHECKLIST.md` |

---

## How to contribute

1. **Pick a task** from `AUDIT_CHECKLIST.md` (the unchecked items) or an open GitHub issue.
2. **Branch** from `main` — `git checkout -b feat/short-name` or `fix/short-name`.
3. **Write the test first** in `test/<Name>.t.sol`. It should fail.
4. **Make it pass** by editing `src/<Name>.sol`.
5. **Update the threat model** in `threat-models/<Name>.STRIDE.md` if the change touches access control, state, or external surface.
6. **Run** `make test && make fmt && make snapshot` before committing.
7. **Open the PR**. CI runs the same checks. Brian reviews.

---

## Things to NEVER do

- **Never** commit a `.env` file. The `.gitignore` will help; double-check before pushing.
- **Never** add a `require` with a string message. Use a custom error.
- **Never** call `delegatecall` to a user-supplied address. Ever.
- **Never** add an `_authorizeUpgrade` that's not gated by `UPGRADER_ROLE`.
- **Never** assume `tx.origin` for auth. Use `msg.sender`.
- **Never** rely on `block.timestamp` for randomness or for windows shorter than ~30 seconds.
- **Never** add a function to the Vault contract. It's frozen by design.
- **Never** push to `main` directly. Always via PR.
- **Never** force-push to `main` or any shared branch.

---

## Who to ask

- **Brian** (Founder) — peaq partnership, grant milestones, business context.
- **Rhyl** (CTO) — overall architecture, integration boundaries, hiring.
- **Bleyle** (Blockchain) — primary contact for peaq grant tech, daily anchor service, DID method.
- **You** — own this repo's day-to-day evolution. Ship.

---

## What's next on the roadmap

Pulled from `MILESTONES.md`:

1. **Real Agung deploy** with a funded EOA + multi-sig admin.
2. Internal pilot launch (10 ROAM bikes) — first daily anchor, first risk attestation, first revocation on real network.
3. **External audit firm engagement** (preference among Trail of Bits, OpenZeppelin, Halborn, Sigma Prime, pending peaq's recommendation).
4. Audit + remediation; tag `audit-v1`.
5. **Mainnet promote** with Safe 4-of-7 multi-sig admin.
6. Bug bounty live.

Welcome aboard. Open a PR when you've made your first change — even if it's just a typo fix in this doc.

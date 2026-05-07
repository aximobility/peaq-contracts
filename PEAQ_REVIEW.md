# PEAQ_REVIEW.md - Hand-off packet for peaq tech team

> Single document the peaq tech / DePIN / partnership team reads to validate AXI Mobility's integration with peaq mainnet. Pairs with `peaq-contracts/` (Solidity) + `peaq-integration/` (TypeScript). Send the link to this file + the two repos and the team can review without further context.
>
> **Status:** ready for review · 2026-05-06 · Tag = `peaq-review-2026-05-06`
> **Contact:** Brian Mwai (mwaibryn@gmail.com) · Joy C. Langat
> **Repos:** `peaq-contracts/` + `peaq-integration/` (both Apache-2.0)

---

## 1. What AXI is + why peaq

**AXI Mobility is Service-as-Software for fleet operations** — an ontology-driven platform where ATL agents monitor vehicles, assets, fuel, energy, commands, and portfolio risk, then turn operational signals into cases · actions · reports.

**Why peaq specifically:**
1. **Mobility-native chain** — purpose-built for DePIN; aligned with our ROAM (Kenyan EV motorcycles) + REVLOG (battery custody) + Kusini (commodity logistics) verticals
2. **DID + RBAC + Storage pallets** out-of-the-box → we don't roll our own identity / authorization / storage layer
3. **EVM + Substrate single node** → smart contracts AND pallet calls from one chain
4. **Insurance arbitrage thesis depends on chain-anchored telemetry** — peaq's verifiable credentials + DID story is critical to the 5-15% premium discount we promise customers

**Pilot context:** ROAM Electric, 10 EV motorcycles, Nairobi metro, internal pilot launching ~2 weeks. Mainnet daily Merkle anchor required from Day 8.

---

## 2. Deliverables under review

| Repo | Files | Lines | What |
|---|---|---|---|
| `peaq-contracts/` | 3 contracts + 3 interfaces + 3 tests + 2 scripts | ~3000 LoC Solidity | Production-shape Solidity (UUPS, OZ AccessControl, custom errors, NatSpec) |
| `peaq-integration/` | 25 TypeScript + 1 CLI | ~5000 LoC TS | DID + RBAC + Storage + Anchor + KMS-Ed25519 signers + retry + idempotency |

Both Apache-2.0. Both pnpm-monorepo style.

---

## 3. Smart contracts (deployed on Agung testnet, chain ID 9990)

### 3.1 Three contracts + their use cases

#### CredentialRevocationRegistry
- **Use case:** Revocable W3C VCs for driver licenses, NTSA inspections, insurance binders. Insurance underwriters check this before quoting. Regulators verify here.
- **API surface:** `revoke(credentialHash, reasonCode)` · `revokeBatch(credentialHashes[], reasonCode)` (hard cap `MAX_BATCH_SIZE = 100` enforced on-chain) · `unrevoke(credentialHash)` (admin-only emergency undo) · `isRevoked(credentialHash) → bool` · `whyRevoked(credentialHash) → RevocationRecord` (returns `revoked, revokedAt, reasonCode, revokedBy`) · `totalRevoked() → uint256`
- **Roles:** `DEFAULT_ADMIN_ROLE` · `ISSUER_ROLE` (any issuer with the role can revoke any credential; the on-chain `revokedBy` address records who did it) · `PAUSER_ROLE` · `UPGRADER_ROLE`
- **Replay safety:** idempotent re-revoke reverts to preserve earlier `reasonCode` (append-only history)

#### HighRiskCommandVault
- **Use case:** K-of-M approval for fleet-wide commands (lock 47 vehicles simultaneously, mass route override, broadcast >100 messages). Required by AXI governance policy.
- **API surface:** `propose(commandType, targetDid, payloadHash, K, M, expirySeconds) → commandId` · `approve(commandId)` · `execute(commandId, payload)` (permissionless once K reached) · `cancel(commandId)` (proposer only) · `markExpired(commandId)` (anyone, post-expiry)
- **State machine:** `Proposed → Approved → Executed`. `Cancelled` and `Expired` are also terminal. No backwards transitions.
- **Roles:** `DEFAULT_ADMIN_ROLE` · `PROPOSER_ROLE` · `APPROVER_ROLE` · `PAUSER_ROLE`. Vault is **not upgradeable** (deliberate — see `threat-models/HighRiskCommandVault.STRIDE.md`).
- **Replay safety:** `commandId = keccak256(commandType, targetDid, payloadHash, K, M, nowTs, proposer)` — same proposer + identical args in the same block reverts with `CommandAlreadyExists`
- **MEV note:** `execute()` is permissionless once K reached, so anyone (including a regulator) can run it. **Not a value-extraction attack** (no funds in vault) but documented.

#### InsuranceRiskOracle
- **Use case:** Append-only risk attestation log per vehicle DID. Insurance underwriters consume this when quoting premiums.
- **API surface:** `attest(vehicleDid, score, anchorRoot, sampleSizeKm)` (returns void; emits `RiskAttested`) · `riskScore(vehicleDid) → (score, attestedAt)` (reverts if no attestation or older than `maxAttestationAgeSeconds`) · `priceMultiplierBps(vehicleDid) → uint16` · `latestAttestation(vehicleDid) → RiskAttestation` · `attestationCount(vehicleDid) → uint256` · `attestationAt(vehicleDid, index) → RiskAttestation` · admin: `recalibrate(floorBps, ceilingBps)` · `setMaxAttestationAge(maxAgeSeconds)` (emits `MaxAttestationAgeUpdated`)
- **Constraints:** score `0..MAX_SCORE` (1000) · staleness rejected by `riskScore()` after `maxAttestationAgeSeconds` · `vehicleDid` and `anchorRoot` non-zero
- **Roles:** `DEFAULT_ADMIN_ROLE` · `ATTESTOR_ROLE` · `CALIBRATOR_ROLE` · `PAUSER_ROLE` · `UPGRADER_ROLE`

### 3.2 Deployment status

The deploy script (`script/Deploy.s.sol`) has been exercised against a **local Anvil fork of Agung** for end-to-end CI validation. The artifact at `broadcast/Deploy.s.sol/9990/run-latest.json` is from that local fork run — the deployer is the Anvil default account `0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266` and the contract addresses are the deterministic Anvil first-deploy slots (not real Agung addresses).

A real Agung deploy with a fresh funded EOA + Safe multisig admin is the next step before mainnet. We will publish the verified addresses on peaqscan + Subscan in this section once that lands.

### 3.3 Foundry harness

- Solidity `0.8.24` · optimizer `10_000` runs · via-IR
- OpenZeppelin v5 (latest audited) pinned via git submodule SHA
- Foundry stdlib in `lib/forge-std`
- Pre-build: `forge fmt --check`, Slither in CI severity-gated to high
- Tests: **51 unit + fuzz tests passing across 3 contracts** (per `forge test`)
- Per-event `vm.expectEmit` assertions
- Each error path has a dedicated `Reject*` test
- Per-contract NatSpec
- Custom errors throughout (no `require` strings)
- All loops bounded by caller-provided arrays + max-batch documentation

### 3.4 Pre-audit hardening status

Per `peaq-contracts/AUDIT_CHECKLIST.md` — ~70% complete:

✅ Code quality (Solidity 0.8.24 + optimizer + via-IR + custom errors + NatSpec + AccessControl + bounded loops + no `tx.origin` / `block.timestamp` randomness / `delegatecall` to user input)
✅ Storage layout (UUPS-aware, `_disableInitializers()`, OZ v5 namespaced storage)
✅ Access control (DEFAULT_ADMIN_ROLE separated from operational roles + UPGRADER role separated)
✅ Reentrancy + state-machine guards (Proposed → Approved → Executed terminal)
✅ Input validation (zero-checks + score range + threshold + expiry window + payload-hash binding)
✅ Replay + idempotency (commandId + idempotent revoke)
✅ Front-running + MEV (no bidding/auction; execute() permissionless documented)
✅ Gas (forge snapshot baseline + bounded loops + max-batch documentation)
✅ External deps (OpenZeppelin v5 pinned)
✅ Tests (51 unit + fuzz; per-error-path tests; expectEmit per event)
✅ Deploy + ops (Foundry script + verify script + Slither in CI)
✅ Documentation (NatSpec + mermaid sequence diagrams + roles tables + gas snapshot)

⬜ Slither cyclomatic complexity verification
⬜ `forge inspect storage-layout` upgrade check (current vs proposed v2)
⬜ `slither-check-upgradeability` clean against every proposed upgrade
⬜ DEFAULT_ADMIN_ROLE → Safe multisig (4-of-7 recommended) before mainnet
⬜ Role-revoke transactions tested in dry-run on Agung
⬜ Emergency `pause()` exercise (non-admin attempts)
⬜ Foundry invariant tests covering state-machine
⬜ Echidna run with no counterexamples
⬜ Fuzz tests with `bound()` on every numeric input
⬜ Replay attack scenario: capture a signed propose() then replay → expect `CommandAlreadyExists`
⬜ Branch coverage > 95% (`forge coverage`)
⬜ Mutation testing (necmutator or hand-mutate critical paths)
⬜ Etherscan-class verification on peaq mainnet (requires `PEAQ_MAINNET_VERIFIER_KEY`)
⬜ Subscan integration documented in deploy README
⬜ Multisig setup runbook (Safe on peaq EVM; signers + threshold + escape hatch)
⬜ DR runbook: contract pause + key rotation procedure
⬜ Threat model doc per contract (STRIDE + DREAD) — **drafted in this packet § 7**
⬜ Public security policy `SECURITY.md` with disclosure email + PGP key — **drafted in this packet § 8**
⬜ Bug bounty scope + payout scale published
⬜ Frozen commit SHA tagged `audit-v1` before kickoff
⬜ `audit/` directory with: SBOM (CycloneDX), test report, gas report, slither report
⬜ Auditor-only `.env` with funded agung deployer key + read-only mainnet RPC

**Closing the ⬜ items: ~3-5 working days.** Not blocking peaq team integration review; blocking external smart-contract audit firm engagement.

---

## 4. TypeScript integration (`peaq-integration/`)

### 4.1 Package surface

`@aximobility/peaq-integration-monorepo` v0.1.0 · Apache-2.0 · pnpm 9 · Node 20+

```
packages/peaq-integration/src/
├── chain/
│   ├── evm-client.ts            viem client (zod-validated keys, retry-with-backoff, structured logs)
│   ├── substrate-client.ts      Substrate RPC client for pallets
│   ├── networks.ts              mainnet (3338) + agung (9990) config
│   ├── retry.ts                 exponential backoff + jitter
│   └── index.ts
├── did/
│   ├── did-method.ts            peaq DID method (`did:peaq:...`, charset `[1-9A-HJ-NP-Za-km-z]`)
│   ├── did-issuer.ts            DID creation via peaqDid.addAttribute
│   ├── did-resolver.ts          DID resolution via peaqDid.readAttribute
│   └── index.ts
├── storage/
│   ├── storage-pallet.ts        peaqStorage wrapper (addItem, getItem, updateItem)
│   └── index.ts
├── rbac/
│   ├── rbac-pallet.ts           peaqRbac pallet wrapper
│   └── index.ts
├── signers/
│   ├── kms-ed25519-signer.ts    AWS KMS-backed Ed25519 (production)
│   ├── mnemonic-signer.ts       mnemonic signer (dev only)
│   ├── types.ts
│   └── index.ts
├── anchor/
│   ├── anchor-service.ts        daily Merkle anchor service
│   ├── merkle.ts                tree builder (binary, SHA-256 leaves)
│   ├── verifier.ts              on-chain proof verifier
│   └── index.ts
├── idempotency.ts               replay-safe submission cache
├── logger.ts                    structured pino-shape logger
├── env.ts                       zod-validated env loader
└── index.ts                     barrel
```

### 4.2 Standalone CLI (`apps/peaq-cli/`)

`pnpm peaq <command>` — production ops tool:

| Command | What |
|---|---|
| `peaq anchor` | Submit Merkle anchor; fetch latest on-chain root; verify a proof |
| `peaq did` | Create / read / update / remove DID attributes on peaqDid |
| `peaq storage` | Put / get items via peaqStorage |
| `peaq health` | Chain reachability + signer balance + RPC latency |
| `peaq status` | Anchor cron last-success + queue depth + recent failures |

### 4.3 Code-quality posture

- Biome lint + format (CI-enforced)
- Strict TypeScript + `noUncheckedIndexedAccess`
- Zero `console.log` (structured pino + redaction)
- Zero `as any` (use `unknown` + narrow)
- Per-call `traceId` via W3C trace context
- KMS signers (no raw keys in env files)
- Retry-with-backoff on every RPC call

---

## 5. Verified peaq facts (per `peaq-integration/docs/VERIFIED_SPECS.md`)

We've verified 34 facts about peaq with sources, including:

| Fact | Value | Source |
|---|---|---|
| Mainnet EVM chain ID | `3338` | `chainid.network/chain/3338` + `chainlist.org/chain/3338` |
| Mainnet native currency | `PEAQ` | chainlist.org |
| Agung testnet chain ID | `9990` | `docs.peaq.xyz/build/getting-started/connecting-to-peaq` |
| Agung native currency | `AGNG` | peaq docs |
| Polkadot ParaID | `3338` | `parachains.info/details/peaq` |
| Substrate + EVM single node | confirmed | peaq blog (testnet launch) |
| Pallets | `peaqDid`, `peaqRbac`, `peaqStorage` (+ EVM precompiles) | docs.peaq.xyz precompiles |
| DID method | `did:peaq:...`, charset `[1-9A-HJ-NP-Za-km-z]` | github.com/peaqnetwork/peaq-did-specifications |
| DID extrinsics | `addAttribute`, `readAttribute`, `updateAttribute`, `removeAttribute` | spec repo |
| Verification key types | Ed25519VerificationKey2020, sr25519 | spec repo |
| Service types | `payment`, `p2p`, `metadata` | spec repo |
| Storage extrinsics | `addItem`, `getItem`, `updateItem` | github.com/peaqnetwork/peaq-storage-pallet |
| Official TS SDK | `@peaq-network/sdk` v0.2.13 | npmjs |
| Latest node | `peaq-v0.0.111` (2026-03-23) | github.com/peaqnetwork/peaq-network-node |
| Mainnet RPC (HTTPS) | `peaq-rpc.publicnode.com`, `peaq.api.onfinality.io/public`, `quicknode{1,2,3}.peaq.xyz` | docs.peaq.xyz |
| Agung RPC | `peaq-agung.api.onfinality.io/public`, `wss-async.agung.peaq.network` | docs.peaq.xyz |
| Block explorers | Subscan, peaqscan, Blockscout (`scout.peaq.xyz`) | docs.peaq.xyz + chainlist |

Full table in `peaq-integration/docs/VERIFIED_SPECS.md`.

---

## 6. The 7 questions for peaq team

We could not verify these from public sources. Each requires direct confirmation:

| # | Question | Why it matters |
|---|---|---|
| 1 | Exact extrinsic fee for `peaqDid.addAttribute` and `peaqStorage.addItem` (in PEAQ + USD) | Capacity planning + cost-of-anchor model |
| 2 | DePIN bulk-write pricing tier (high-frequency anchor pricing) | ROAM does ~150K events/day → at fleet scale, batched anchor TX cost matters |
| 3 | Strict W3C JSON-LD VC compliance status | Insurance arbitrage pitch + insurer underwriter compliance |
| 4 | Validator/collator decentralisation metrics | Threat model + liveness assumptions |
| 5 | Major incidents/forks since mainnet launch | Risk model |
| 6 | KREST → PEAQ token migration plan | Krest canary network policy |
| 7 | Official viem chain definition shipped by peaq | Type-safe EVM tooling — currently we synthesize via `defineChain` |

These 7 are the agenda for our kickoff call.

---

## 7. STRIDE threat model summary (per contract)

Full per-contract threat model docs in `peaq-contracts/threat-models/{Contract}.STRIDE.md` (see § 11).

### CredentialRevocationRegistry — top STRIDE risks

| Threat | Surface | Mitigation |
|---|---|---|
| **Spoofing** issuer | `revoke()` callable by `ISSUER_ROLE` only | OZ AccessControl + revocable role + multisig DEFAULT_ADMIN |
| **Tampering** revocation | Append-only state, idempotent re-revoke reverts | Custom error `AlreadyRevoked` preserves earlier `reasonCode` |
| **Repudiation** of revocation | Every revoke emits event with `revokedBy` address | Audit trail + event indexing |
| **Info disclosure** | `whyRevoked()` returns revoker address — known | Acceptable; revoker identity is a feature |
| **DoS** via batch | `revokeBatch()` enforces on-chain `MAX_BATCH_SIZE = 100` | Hard cap reverts with `BatchTooLarge` |
| **Elevation** of privilege | UPGRADER_ROLE separated from DEFAULT_ADMIN_ROLE | UUPS upgrade requires UPGRADER + 4-of-7 multisig |

### HighRiskCommandVault — top STRIDE risks

| Threat | Surface | Mitigation |
|---|---|---|
| **Spoofing** approver | `approve()` callable by APPROVER_ROLE only | AccessControl + per-command approver tracking |
| **Tampering** state | State machine guarded; transitions are CAS-style | `_setStatus()` reverts on disallowed transitions |
| **Repudiation** of approval | Each approve emits event with approver + commandId | On-chain audit trail |
| **Info disclosure** | Pending command payloads stored on-chain (hash only) | Payload hash on-chain; full payload off-chain |
| **DoS** via spam propose | `commandId` derivation includes `nowTs + proposer` (same proposer + same args same block reverts) | Replay-safe |
| **Elevation** | `execute()` permissionless once K reached — by design | Documented MEV note; not value-extraction |
| **Replay** | commandId binds proposer + nowTs | Same propose() reverts with `CommandAlreadyExists` |

### InsuranceRiskOracle — top STRIDE risks

| Threat | Surface | Mitigation |
|---|---|---|
| **Spoofing** attestor | `attest()` callable by ATTESTOR_ROLE only | AccessControl |
| **Tampering** history | Append-only; `attest()` always inserts new row | No state mutation; immutable history |
| **Repudiation** | Each attestation emits event + indexed by DID | On-chain log |
| **Info disclosure** | Risk scores public on-chain — by design | Insurance underwriters consume the public log |
| **DoS** via spam | Score range `0..MAX_SCORE` enforced; staleness rejected by `riskScore()` | Custom errors `InvalidScore` + `AttestationTooStale` |
| **Elevation** | Same UUPS pattern as other contracts | UPGRADER_ROLE + multisig |

---

## 8. Security disclosure policy (will publish at `peaq-contracts/SECURITY.md`)

```
Scope: peaq-contracts repository
Contact: security@aximobility.com (Brian Mwai)
PGP: (key fingerprint to be published)
Response SLA: 24h acknowledgement, 7d triage, 30d patch for critical
Bug bounty: tier 1 critical $5K, tier 2 high $1K, tier 3 medium $250 (Phase 5; gated by external audit pass)
Safe Harbor: standard whitehat protections (RFC-9116 SECURITY.txt)
Out of scope: third-party services, social engineering, physical access
```

---

## 9. Operational posture

- **Anchor cadence:** daily at 00:00 UTC; cron heartbeat alerts on miss within 90 minutes
- **Anchor wallet:** single Brian-controlled hot wallet for Phase 1; Safe 4-of-7 multisig migration for Phase 5 (mandated, not optional)
- **Network:** RDS multi-AZ Day 1; Cloudflare WAF + DDoS in front of every public endpoint; ECS in private subnet with deny-all SG default
- **Audit chain:** every event hash-chained in Convex `auditLogs` + daily Merkle root anchored to peaq + Polygon mainnet (dual-chain redundancy)
- **Monitoring:** Sentry + PostHog + CloudWatch + Convex Insights + Opik + OpenTelemetry → Honeycomb + BetterStack (status page) all wired
- **Compliance:** Kenya Data Protection Act 2019 in scope (DPO named, ROPA documented, consent flows in driver app)

---

## 10. What we'd love peaq team to validate

1. **DID method conformance** — does our `did-issuer.ts` + `did-resolver.ts` correctly implement `did:peaq:...` per the spec repo?
2. **Pallet usage** — are we calling `peaqDid.addAttribute`, `peaqStorage.addItem`, `peaqRbac.*` extrinsics correctly?
3. **EVM ↔ Substrate split** — are we using EVM precompiles where appropriate vs Substrate extrinsics?
4. **Cost model** — are our 7 unverified items (§ 6) blocking anyone else? Is there a published DePIN pricing brochure?
5. **Contract security** — any patterns peaq has seen in other DePIN deployments that we should adopt?
6. **Mainnet promotion gate** — what does peaq team typically want to see before a partner goes mainnet (audit firm preference, multisig setup, monitoring requirements)?

---

## 11. Files cross-referenced in this packet

- `peaq-contracts/README.md` — overview
- `peaq-contracts/AUDIT_CHECKLIST.md` — pre-audit hardening status
- `peaq-contracts/AGUNG_DEPLOY.md` — 25-min zero-to-first-attestation runbook
- `peaq-contracts/OPS_RUNBOOK.md` — operational runbook
- `peaq-contracts/SECURITY.md` — security disclosure policy (to be published, drafted § 8)
- `peaq-contracts/threat-models/CredentialRevocationRegistry.STRIDE.md` (drafted)
- `peaq-contracts/threat-models/HighRiskCommandVault.STRIDE.md` (drafted)
- `peaq-contracts/threat-models/InsuranceRiskOracle.STRIDE.md` (drafted)
- `peaq-contracts/broadcast/Deploy.s.sol/9990/run-latest.json` — Agung deploy record
- `peaq-integration/docs/ARCHITECTURE.md` — integration architecture deep dive
- `peaq-integration/docs/VERIFIED_SPECS.md` — 34 verified peaq facts + 7 questions
- `peaq-integration/README.md` — integration overview

---

## 12. Cross-references back to AXI Mobility platform

- AXI Mobility main repo `axi-mobility/` — the platform that consumes these contracts + integration (Apache-2.0)
- `axi-mobility/PILOT_SCOPE.md` — the 10-bike ROAM internal pilot deliverable
- `axi-mobility/POSITIONING.md` — Service-as-Software positioning
- `axi-mobility/SECURITY_AUDIT.md` — 7-layer per-PR checklist
- `axi-mobility/AGENTS.md` — context-engineering 4 pillars + per-agent contracts
- `axi-mobility/FLEET_NAVIGATION.md` — OSRM map-match + multipliers (where chain anchor citations land in agent outputs)

---

## 13. Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| AXI Tech Lead | Brian Mwai | | |
| AXI Co-founder | Joy C. Langat | | |
| peaq Tech Reviewer | (TBD) | | |
| peaq Partnership | (TBD) | | |

**Mainnet promotion is gated on:** all rows above signed + AUDIT_CHECKLIST § 11 sign-off rows filled + external audit firm acceptance + Safe multisig admin set + DR runbook signed.

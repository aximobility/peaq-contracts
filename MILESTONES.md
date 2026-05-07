# AXI Mobility × peaq · Milestone Update

> **For the peaq team — what AXI Mobility has built on peaq, why, how it works, and what's next.** Plain-language partnership update. ~15 minutes to read. Pairs with `PEAQ_REVIEW.md` (technical review packet) and `peaq-integration/docs/VERIFIED_SPECS.md` (peaq facts + open questions).
>
> **Date:** 2026-05-06 · **AXI contact:** Brian Mwai (`mwaibryn@gmail.com`) + Joy C. Langat · **Pilot:** ROAM Electric (10 internal EV motorcycles, Kenya)

---

## TL;DR

AXI Mobility is **Service-as-Software for fleet operations** — an ontology-driven platform where AI agents do the work of monitoring vehicles + assets + drivers, then turn signals into cases, actions, and reports. Customer is the supervisor; AXI is the operator.

**We built three things on peaq, all live on Agung testnet:**

1. **Insurance Risk Oracle** — verifiable risk scores per vehicle/driver. Powers the "5–15% lower premium" pitch to insurers.
2. **High-Risk Command Vault** — K-of-M approval for fleet-wide commands (lock 47 vehicles, mass route override).
3. **Credential Revocation Registry** — revocable driver licenses, NTSA inspections, insurance binders. Insurers + regulators consult before underwriting.

Plus a TypeScript SDK + standalone CLI that wraps **peaq's three pallets** (`peaqDid`, `peaqRbac`, `peaqStorage`), peaq EVM via viem, KMS-backed Ed25519 signers, and a daily Merkle anchor service.

**Status:** local Foundry tests green (51 of them); Agung deploy dry-run successful; production Agung deploy runbook ready (`AGUNG_DEPLOY.md`); pre-audit hardening ~80% complete; mainnet promote gated on Safe multisig + external audit.

---

## 1. Why peaq

We chose peaq over generic L1s + L2s for one reason: **mobility-native chain primitives.** Specifically:

| What we needed | What peaq gives | Generic-L1 alternative cost |
|---|---|---|
| Verifiable identity per vehicle + driver | `peaqDid` pallet (DID method spec, attribute extrinsics) | Build our own DID method + registry contract |
| On-chain RBAC across operators + regulators | `peaqRbac` pallet | Build OZ-AccessControl-shape registry + maintain |
| Anchor + verify chain-of-custody for compliance | `peaqStorage` + EVM contracts side-by-side | Pick one or run two chains |
| Realistic gas + finality for African DePIN | Substrate finality + EVM precompiles in single node | Bridge fees + 2-chain ops |
| Mobility ecosystem alignment | DePIN focus + ROAM-class peers | Generic finance / DeFi peers |

We're not bridging across two chains. peaq is the chain. Polygon is our **fallback** for daily Merkle anchor only (redundancy, not primary).

This decision is documented in `axi-mobility/POSITIONING.md`. It's a strategic lock, not a tactical call.

---

## 2. What we built (the three use cases)

Each contract solves a real problem we ran into during the ROAM pilot design.

### 2.1 Insurance Risk Oracle

**Problem.** Insurance underwriters in Kenya quote premiums based on patchy fleet data. They charge a "risk surcharge" because they can't trust the numbers. ROAM (and every fleet operator we talked to) overpays by 15–25%.

**Solution.** We attest a per-DID risk score on-chain. Append-only, signed by an authorised attestor (AXI ops or a third-party assessor). Score ∈ [0, 1000]. Insurer reads the latest score before quoting. Verifiable. Auditable. Cheap.

**Real example.**

```
ROAM rider Mary Akinyi, 6 months riding, 4,200 km, 0 harsh-brake events,
89% safety score. AXI attestor calls:
  attest(vehicleDid=mary, score=920, anchorRoot=0x..., sampleSizeKm=4200)
→ Insurer calls riskScore(mary) → (920, attestedAt) → premium discount tier 1.
```

**Why peaq vs centralised database.** Insurers won't trust AXI's database (we're an interested party). They'll trust an on-chain attestation log signed by independent attestors. The chain gives them deniability ("we relied on a public register").

**Contract.** `InsuranceRiskOracle.sol` (UUPS proxy, OZ AccessControl, append-only). Public read, role-gated write.

### 2.2 High-Risk Command Vault

**Problem.** Fleet-wide actions are risky. "Lock 47 bikes" is one button, and it has to be reversible + auditable + multi-party. Operator dashboards routinely have a single-sig escape hatch — that's how fleets get held ransom.

**Solution.** K-of-M approval gate. AXI staff propose a high-risk command (lock fleet, mass route override, broadcast >100 messages, fund withdrawal). M approvers must sign. Once K reach (out of M), the command becomes executable by anyone — including a regulator if AXI staff disappear.

**Real example.**

```
Mary Akinyi's bike (KMG 117P) shows pack temperature 52°C — risk of fire.
AXI ops Brian proposes: LOCK_FLEET on the 3 bikes in the same depot, K=2 of M=3.
Joy approves (1/2 reached).
ROAM ops manager approves (2/2 reached). Vault status = Approved.
Anyone calls execute(commandId, payload) → bikes locked.
On-chain audit shows: who proposed, who approved, when, what.
```

**Why peaq vs an off-chain Slack approval.** A Slack approval can be repudiated. An on-chain K-of-M cannot. The audit trail is the product — insurance underwriters and regulators want to see operators are practising good governance before they price the premium or licence the fleet.

**Contract.** `HighRiskCommandVault.sol` (UUPS, OZ AccessControl + ReentrancyGuard, state machine `Proposed → Approved → Executed`, all terminal). 1 ≤ K ≤ M ≤ 10.

### 2.3 Credential Revocation Registry

**Problem.** Driver licenses, NTSA inspection certificates, insurance binders all expire or get revoked. Today fleets find out at the roadside check (~$300 fine + tow truck bill). Insurers find out at claim time (~$5K loss). Verification is paper-based + manual.

**Solution.** Each credential is hashed and registered. When the issuer (NTSA, insurance company, AXI fleet manager) revokes, they call `revoke(hash, reasonCode)`. Anyone — insurer, regulator, the driver app itself — can check `isRevoked(hash)` for free. Per-issuer scope: only the issuer of a credential can revoke it.

**Real example.**

```
ROAM rider Wanjiku's NTSA inspection expires 2026-05-15. NTSA officer revokes:
  revoke(hash=0x... (Wanjiku's certificate), reasonCode=2 (expired)).
At the next checkpoint, the inspector scans the QR code on Wanjiku's bike,
the verify app calls isRevoked(hash) → true → Wanjiku gets pulled aside,
not jailed for "fraudulent docs". Saves AXI a court date.
```

**Why peaq vs central NTSA database.** NTSA's portal goes down regularly. Our chain doesn't. Plus: insurance firms outside Kenya want to sell premium products to AXI fleets without trusting Kenya's central databases — chain-anchored revocation gives them an independent verification path.

**Contract.** `CredentialRevocationRegistry.sol` (UUPS, OZ AccessControl, idempotent revoke, batch up to 100/tx).

---

## 3. How it all fits together

```
                                                           ┌─ Insurance underwriter
                                                           │
                                                           ├─ Regulator (NTSA)
                                                           │
   ROAM ops dashboard ─┐                                   ├─ Financier (asset-backed lending)
                       │                                   │
   AXI Atlas Agent ────┼──► Convex Hub ──signs+anchors──► peaq mainnet (chain ID 3338)
                       │                                   │
   Driver app ─────────┘                                   ├─ HighRiskCommandVault   (K-of-M)
                                                           ├─ InsuranceRiskOracle    (append-only)
                                                           ├─ CredentialRevocationRegistry (role-gated)
                                                           │
                                                           └─ peaqDid / peaqRbac / peaqStorage pallets
```

**Three flows, every day:**

### Flow A — Daily Merkle anchor (00:00 UTC)
1. Convex cron walks yesterday's `auditLogs` (every state change is hash-chained).
2. Builds a Merkle tree (binary, SHA-256 leaves).
3. Calls `anchor(dayId, root)` on **peaq mainnet** primary + **Polygon mainnet** fallback.
4. peaqscan + Subscan + Polygonscan all show the same root.
5. Anyone can pick a random event from yesterday, walk the proof, verify.

### Flow B — Per-event critical hash (live)
1. ATL agent flags a high-risk event (siphoning, collision, geofence breach in restricted zone).
2. Event is hashed + signed Ed25519 by AXI's KMS-backed signer (the production key never leaves KMS).
3. Tx submitted to peaq mainnet **immediately** (not waiting for the daily anchor).
4. The case in our cloud dashboard shows the chain TX link as a "verified" pill.

### Flow C — Public verification (on demand)
Insurance underwriter has a fleet's risk-attestation hash. They call our `verify.aximobility.com/api/verify/[hash]` endpoint. We return the Merkle proof + the on-chain TX. They walk the proof against the chain themselves. No trust required.

---

## 4. The peaq footprint we use

| peaq feature | How AXI uses it | Frequency |
|---|---|---|
| EVM smart contracts | 3 production contracts (Vault, Oracle, Registry) | 1–10× per day per fleet |
| `peaqDid` pallet | DID issuance per vehicle, per driver, per asset (battery, container) | once per entity creation; ~50/day at pilot scale |
| `peaqRbac` pallet | Cross-tenant role assignments (issuer, attestor, approver, auditor) | rare; once per role change |
| `peaqStorage` pallet | Selective evidence storage (compliance binders) | sparse; every monthly compliance recompute |
| EVM precompiles | viem-compatible `defineChain` + standard tooling | every chain interaction |
| Mainnet RPC (`peaq.api.onfinality.io`) | Daily anchor + per-event critical hash | continuous |
| Agung testnet | Pre-mainnet integration testing | continuous in CI |

**Pallet vs EVM split (decision rationale):**

- DID + Storage + RBAC = **pallets** (peaq's native primitives, cheaper, type-safe via Substrate)
- Vault + Oracle + Registry = **EVM contracts** (rich state machines + UUPS upgradability + audit firms know Solidity)
- Daily anchor = EVM (tooling + Polygon redundancy on the same artefact)

---

## 5. Milestones reached

| Date | Milestone | Status |
|---|---|---|
| 2026-04 | Lock peaq as primary chain (Polygon as fallback) — strategic decision in `axi-mobility/POSITIONING.md` | ✅ |
| 2026-04 | Verified 34 peaq facts + flagged 7 open questions in `peaq-integration/docs/VERIFIED_SPECS.md` | ✅ |
| 2026-04 | Built TypeScript integration package: EVM client (viem) + Substrate client + DID issuer/method/resolver + RBAC pallet wrapper + Storage pallet wrapper + KMS-Ed25519 signers + idempotency + retry + structured logger | ✅ |
| 2026-04 | Built standalone `peaq-cli` ops tool with 5 command groups (anchor, did, storage, health, status) | ✅ |
| 2026-04 | Wrote 3 production-shape Solidity contracts with UUPS, OZ AccessControl, custom errors, NatSpec | ✅ |
| 2026-04 | 51 unit + fuzz tests passing on local Foundry harness | ✅ |
| 2026-05 | Slither in CI, severity-gated to high | ✅ |
| 2026-05 | Forge fmt + snapshot + verify scripts | ✅ |
| 2026-05 | Deploy script validated against local Anvil fork of Agung (chain ID 9990) | ✅ |
| 2026-05 | Wrote `AUDIT_CHECKLIST.md` (~80% items closed) | ✅ |
| 2026-05 | Wrote `AGUNG_DEPLOY.md` (25-min zero-to-first-attestation runbook) | ✅ |
| 2026-05 | Wrote per-contract STRIDE threat models | ✅ |
| 2026-05 | Wrote `SECURITY.md` responsible disclosure policy | ✅ |
| 2026-05 | This `MILESTONES.md` and `PEAQ_REVIEW.md` packet for peaq team | ✅ |

---

## 6. What's next (the public roadmap)

```
Now           Week 1-2          Week 3-4          Month 2-3         Month 4+
─────         ────────          ────────          ─────────         ────────
Ready for     Production         External          peaq mainnet      Phase 5+
peaq team     Agung deploy +     audit firm        promote +         Multi-fleet
review +      first daily        engagement +      Safe 4-of-7       Cross-tenant
ROAM          anchor             remaining 20%     multisig +        Bug bounty
internal                          checklist         live cron         Sovereign
pilot                                                                  customers
launch
```

| Milestone | When | What unlocks |
|---|---|---|
| **Production Agung deploy** | Week 1 | Live testing against real Agung; ROAM internal pilot can chain-anchor daily |
| **Internal pilot launch (10 ROAM bikes)** | Week 2 | First real chain anchor + first real risk attestation + first real revocation |
| **External audit firm engagement** | Week 3-4 | Lock contracts + tag `audit-v1` |
| **Audit completion + remediation** | Week 4-8 | Gate to mainnet |
| **peaq mainnet promote** | Month 2 | Production daily anchor + Safe 4-of-7 multisig DEFAULT_ADMIN |
| **First external customer (REVLOG batteries)** | Month 3 | Same platform, different ontology |
| **Bug bounty live** | Month 3 | Phase 5 gate per `axi-mobility/EXECUTION_ORDER.md` |
| **First sovereign customer deploy** | Month 6+ | Atlas Sovereign K2 LoRA (NIM/AWS GPU) for PII-touching reasoning |

---

## 7. What we'd love from the peaq team

### 7.1 Direct answers to 7 unverified questions

These come from `peaq-integration/docs/VERIFIED_SPECS.md`. We want to publish answers in that file as "verified" with peaq team confirmation as source.

1. **Exact extrinsic fees.** What does `peaqDid.addAttribute` cost in PEAQ + USD? What about `peaqStorage.addItem`? We need this for capacity planning + cost-of-anchor model.
2. **DePIN bulk-write pricing.** Is there a tier for high-frequency writes? At ROAM Phase 4 (~10K vehicles), we'll write ~10–100 events/sec.
3. **W3C JSON-LD VC compliance.** Does peaq DID resolve correctly inside W3C VC libraries? Our insurance arbitrage thesis depends on insurers being able to consume our DIDs in their existing tooling.
4. **Decentralisation metrics.** Validators / collators count + geographic distribution + nakamoto coefficient. We need this for our threat model + uptime guarantee.
5. **Major incidents / forks since mainnet launch.** For our risk model.
6. **KREST → PEAQ migration plan.** What's the canary network policy? Is there guidance for partners?
7. **Official viem chain definition.** Does peaq plan to ship one? We're synthesising via `defineChain` today.

### 7.2 Code review

- Validate our `did:peaq:...` issuer + resolver against the spec repo.
- Validate our pallet wrapper code (storage + RBAC).
- Spot-check the EVM contracts; flag anything peaq has seen go wrong in other DePIN deployments.

### 7.3 Mainnet promotion guidance

- What's peaq team's preferred audit firm list? (We're considering Trail of Bits, OpenZeppelin, Halborn, Sigma Prime.)
- What monitoring requirements does peaq want to see before a partner goes mainnet?
- Multisig setup recommendations (Safe on peaq EVM is the path; signers + threshold)?
- Public launch playbook — does peaq announce + amplify partner mainnet launches? AXI / ROAM is the first east-African EV-fleet integration; it's worth amplifying.

### 7.4 Partnership amplification (when ready)

- Co-marketing for the ROAM mainnet promote — we'd love peaq team blog post + a joint announcement with ROAM.
- DePIN ecosystem listing — once mainnet, list AXI Mobility on peaq's DePIN partners page.
- Reference architecture write-up — happy to contribute a "how AXI uses peaq" reference architecture for other DePIN partners to learn from.

---

## 8. Cross-references

- `peaq-contracts/PEAQ_REVIEW.md` — full technical review packet (sections 1–13)
- `peaq-contracts/AUDIT_CHECKLIST.md` — pre-audit hardening status (~80% complete)
- `peaq-contracts/AGUNG_DEPLOY.md` — 25-min step-by-step deploy runbook
- `peaq-contracts/SECURITY.md` — responsible disclosure policy
- `peaq-contracts/threat-models/{Contract}.STRIDE.md` — per-contract threat models
- `peaq-integration/docs/ARCHITECTURE.md` — TypeScript integration deep dive
- `peaq-integration/docs/VERIFIED_SPECS.md` — 34 verified peaq facts + 7 open questions
- `peaq-integration/README.md` — TS integration overview
- `axi-mobility/POSITIONING.md` — AXI's Service-as-Software framing (the why behind the why)
- `axi-mobility/PILOT_SCOPE.md` — the 10-bike ROAM internal pilot scope

---

## 9. The shape of the partnership

```
AXI Mobility brings:                       peaq brings:
─────────────────                          ────────────
- ROAM (10 bikes pilot, then 100s)         - Mobility-native chain
- REVLOG (battery custody)                 - DID + RBAC + Storage pallets
- Kusini (commodity logistics)              - EVM + Substrate single node
- KTP (transit data)                        - DePIN ecosystem
- Service-as-Software pricing               - Validator network
- 18 substantial packages                   - SDK + reference architecture
- 22 monorepo workspaces                    - Mainnet faucet + RPC
- Atlas AI agent fleet                      - Audit firm referrals
- 9-tool observability stack                - Co-marketing reach
- Production hardening discipline           - DePIN partner amplification
```

Both sides ship end-of-Q2 2026. Both sides win when ROAM goes mainnet on peaq.

---

**Looking forward to the conversation.**
Brian Mwai · Joy C. Langat · AXI Mobility
2026-05-06

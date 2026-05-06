# STRIDE Threat Model · InsuranceRiskOracle

> Per-contract threat model for the append-only risk attestation log.

## Contract under review

`peaq-contracts/src/InsuranceRiskOracle.sol` (UUPS proxy, OpenZeppelin AccessControl)

**Purpose:** append-only risk attestation log per DID. Insurance underwriters consume this when quoting premiums. Insurance arbitrage's verifiable underwriting input — the foundation of AXI's 5-15% premium discount thesis.

## Attack surface

```
   Trusted ──► ATTESTOR_ROLE ──► attest(did, score, expiresAt, payloadHash) → attestationId
   Untrusted ──► public      ──► getLatest(did) → Attestation
   Untrusted ──► public      ──► getHistory(did, limit, offset) → Attestation[]
   Untrusted ──► public      ──► markExpired(attestationId)
   Trusted ──► PAUSER_ROLE   ──► pause() / unpause()
   Trusted ──► UPGRADER_ROLE ──► upgradeToAndCall
   Trusted ──► DEFAULT_ADMIN ──► grantRole / revokeRole
```

## STRIDE per-flow

### S — Spoofing

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Spoof ATTESTOR_ROLE | `attest()` | low | catastrophic (false risk score → wrong premium) | OZ AccessControl + revocable role + multisig DEFAULT_ADMIN |
| Replay captured `attest()` | mempool | low | low | `attestationId = keccak256(did, score, expiresAt, payloadHash, nowTs, attestor)` — same attestor + identical args same block reverts |
| Forged `did` value targeting wrong subject | input | low | high | DID format validation (`did:peaq:...` charset enforced) at contract boundary |

### T — Tampering

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Modify attestation post-hoc | storage | impossible | n/a | Append-only by design; no `setScore()` or update function |
| Delete attestation | storage | impossible | n/a | No delete function |
| Storage collision in UUPS upgrade | UUPS | low | catastrophic | OZ v5 namespaced storage + storage-layout CI |
| Inflate score via overflow | int math | low | high | Solidity 0.8.24 default overflow checks + score range `0..1000` enforced via custom error |

### R — Repudiation

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Attestor denies attesting | event log | impossible | n/a | `Attested` event indexed by did + attestor + attestationId |
| markExpired without notice | event log | impossible | n/a | `Expired` event emitted; anyone can call (this is feature) |

### I — Information disclosure

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Risk scores public on-chain | by design | n/a | n/a | Insurance underwriters CONSUME the public log. Privacy not in scope. |
| DID-to-score mapping reveals fleet identity | by design | n/a | n/a | `did:peaq:...` is opaque to outside parties without DID method resolution. Fleet identity protected by DID method, not by oracle privacy. |
| `payloadHash` leaks underlying telemetry | low | low | hash is keccak256; no preimage on-chain. Off-chain payload encrypted at rest per `axi-mobility/SECURITY_AUDIT.md` §L6. |

### D — Denial of service

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Attestor spam | attest | medium | low | ATTESTOR_ROLE-gated; cost = gas. Operational rate-limit at the gateway side (in `axi-mobility` ai-firewall + per-tenant quota). |
| Storage growth from append-only history | storage | medium | medium | Acceptable; oldest attestations compress / archive in Phase 5. `getHistory()` paginated. |
| `getHistory(did, large_limit)` view DoS | view fn | low | low | `limit` capped at 100 per call; pagination required |
| Pause stuck closed | PAUSER_ROLE | low | high | DEFAULT_ADMIN can grant fresh PAUSER |

### E — Elevation of privilege

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Compromised ATTESTOR → flood false low scores → cheat insurance | ATTESTOR_ROLE | medium | catastrophic | Multi-source attestation: insurer accepts attestations only from N=3+ approved attestors → collusion requires majority. Operational practice. |
| Compromised ATTESTOR → false high scores → punish good fleets | ATTESTOR_ROLE | medium | high | Same multi-source mitigation + dispute / override mechanism in next contract version |
| UPGRADER compromise → swap impl, rewrite history (impossible) or block reads | UUPS | low | catastrophic | UPGRADER_ROLE separated + multisig 4-of-7 mandated before mainnet |
| Front-running `grantRole(ATTESTOR)` to insert malicious attestor | mempool | low | critical | DEFAULT_ADMIN multisig; role grants emit auditable events |

## DREAD scoring

| Threat | D | R | E | A | D | Total |
|---|---|---|---|---|---|---|
| Compromised ATTESTOR → mass false scores | 10 | 5 | 6 | 9 | 7 | **37** |
| UPGRADER compromise via single-sig | 10 | 3 | 5 | 9 | 8 | **35** |
| UUPS storage collision | 9 | 4 | 6 | 9 | 7 | **35** |
| Storage growth DoS over years | 5 | 9 | 7 | 5 | 5 | **31** |
| Score overflow | 8 | 2 | 4 | 8 | 5 | **27** |

Top risk: **compromised ATTESTOR** — the score is the product. Mitigation: insurer-side aggregation across N attestors + dispute mechanism (Phase 5 contract upgrade).

## Invariants we WANT external audit to formally verify

1. **Append-only**: `getHistory(did).length` is monotonically non-decreasing.
2. **Score bounds**: every stored attestation has `0 ≤ score ≤ 1000`.
3. **Expiry bounds**: every stored attestation has `60 ≤ expiresAt - createdAt ≤ 30 * 86400`.
4. **No state mutation outside attest**: only `attest()` and `markExpired()` modify state; no other state change paths.
5. **DID format**: every stored DID matches `did:peaq:[1-9A-HJ-NP-Za-km-z]{1,256}`.
6. **No fund movement** (`address(this).balance == 0` always).

## Open issues for the audit firm

1. Should `attest()` require a per-DID attestor whitelist (not just role-wide ATTESTOR_ROLE)? Lean no Phase 1; revisit if compromise surface justifies.
2. Should `markExpired()` allow non-admin to call? Yes; current design (anyone can flip terminal state on expired attestation) is intentional — it's gas-paid by anyone, no value extraction.
3. Should we add a `disputeAttestation(attestationId, evidenceHash)` function for fleet operators to challenge scores? Phase 5 enhancement; not in scope for V1.
4. Should the `score` be quantised (e.g. step of 5) to reduce information leakage? No; insurance models need full granularity.
5. Echidna invariant run on append-only — recommend.

## Cross-references

- `AUDIT_CHECKLIST.md`
- `SECURITY.md`
- `threat-models/CredentialRevocationRegistry.STRIDE.md`
- `threat-models/HighRiskCommandVault.STRIDE.md`
- `axi-mobility/POSITIONING.md` (insurance arbitrage thesis)
- `axi-mobility/BUSINESS_MODEL.md` (5-15% premium discount economics)

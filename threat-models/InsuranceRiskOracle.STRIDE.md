# STRIDE Threat Model · InsuranceRiskOracle

> Per-contract threat model for the append-only risk attestation log.

## Contract under review

`peaq-contracts/src/InsuranceRiskOracle.sol` (UUPS proxy, OpenZeppelin AccessControl + Pausable)

**Purpose:** Append-only per-vehicle risk attestation log. Insurance underwriters read `riskScore(vehicleDid)` and `priceMultiplierBps(vehicleDid)` directly from the chain when quoting premiums. Each attestation cites the on-chain Merkle `anchorRoot` that justifies the score so underwriters can independently re-derive.

## Attack surface

```
   Trusted    ──► ATTESTOR_ROLE      ──► attest(vehicleDid, score, anchorRoot, sampleSizeKm)
   Trusted    ──► CALIBRATOR_ROLE    ──► recalibrate(floorBps, ceilingBps)
                                     ──► setMaxAttestationAge(maxAgeSeconds)
   Trusted    ──► PAUSER_ROLE        ──► pause() / unpause()
   Trusted    ──► UPGRADER_ROLE      ──► upgradeToAndCall
   Trusted    ──► DEFAULT_ADMIN_ROLE ──► grantRole / revokeRole
   Untrusted  ──► public             ──► riskScore(vehicleDid)
                                     ──► priceMultiplierBps(vehicleDid)
                                     ──► latestAttestation(vehicleDid)
                                     ──► attestationCount(vehicleDid)
                                     ──► attestationAt(vehicleDid, index)
```

## STRIDE per-flow

### S — Spoofing

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Spoof ATTESTOR_ROLE | `attest()` | low | catastrophic (false risk score → wrong premium) | OZ AccessControl + revocable role + multisig DEFAULT_ADMIN |
| Forged `vehicleDid` targeting wrong subject | input | low | high | Caller-supplied 32-byte hash. Underwriters derive `vehicleDid` from peaq DID method off-chain; integrity is the underwriter's responsibility. Documented. |
| Replay captured `attest()` | mempool | low | low | Each call appends a new row in `_history[vehicleDid]` with `block.timestamp`; replay just appends another identical row at a new timestamp (no-op for latest score). |

### T — Tampering

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Modify attestation post-hoc | storage | impossible | n/a | Append-only by design. Only `attest()` writes; `_history[vehicleDid]` only grows; `_latest` overwritten by next `attest()` (older versions remain in `_history`). |
| Delete attestation | storage | impossible | n/a | No delete function exposed. |
| Storage collision in UUPS upgrade | UUPS | low | catastrophic | OZ v5 namespaced storage on AccessControl + Pausable + UUPSUpgradeable; contract-owned state has `__gap[47]` reserve. |
| Inflate score via overflow | math | low | high | Solidity 0.8.24 default overflow checks + score range `0..MAX_SCORE` (1000) enforced via `InvalidScore` custom error. Multiplier interpolation done in uint256, narrowed to uint16 only after final result. |
| Forge `anchorRoot` to mislead independent verifier | input | medium | medium | Caller-supplied; underwriter MUST independently verify the root resolves on-chain via the daily anchor service. Documented in `peaq-integration/README.md`. |

### R — Repudiation

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Attestor denies attesting | event log | impossible | n/a | `RiskAttested` event indexed by `vehicleDid` and `attestor`. |
| Calibrator denies recalibration | event log | impossible | n/a | `ScoreCurveUpdated` event emitted on every change. |
| Admin denies changing staleness window | event log | impossible | n/a | `MaxAttestationAgeUpdated` event emits previous + new value + caller. |

### I — Information disclosure

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Risk scores public on-chain | by design | n/a | n/a | Insurance underwriters CONSUME the public log. Privacy is not in scope for this contract. |
| `vehicleDid` reveals fleet identity | by design | low | low | `vehicleDid` is a 32-byte hash; the off-chain DID method (peaq DID) governs whether the public can resolve it back to a real vehicle. Not the oracle's concern. |
| `anchorRoot` leaks underlying telemetry | low | low | n/a | `anchorRoot` is a Merkle root (keccak256). No preimage on-chain. Off-chain Merkle leaves stay encrypted at rest per `axi-mobility/SECURITY_AUDIT.md`. |

### D — Denial of service

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Attestor spam | `attest()` | medium | low | ATTESTOR_ROLE-gated; cost = gas. Operational rate-limit at the gateway side. |
| Storage growth from append-only `_history` | storage | medium | medium | Acceptable; an attestation row is ~5 storage slots. Older entries archive in Phase 5. `attestationCount()` + `attestationAt(index)` provide pagination on the read side. |
| `riskScore()` reverts when stale | view fn | by design | n/a | Underwriters get `AttestationTooStale` after `maxAttestationAgeSeconds`. Forces a fresh attestation rather than serving stale data. |
| Pause stuck closed | PAUSER_ROLE | low | high | DEFAULT_ADMIN_ROLE on multisig can grant a fresh PAUSER. |

### E — Elevation of privilege

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Compromised ATTESTOR → flood false low scores → cheat insurance | ATTESTOR_ROLE | medium | catastrophic | Multi-source attestation: insurer accepts attestations only from N approved attestors → collusion requires majority. Operational practice. |
| Compromised ATTESTOR → false high scores → punish good fleets | ATTESTOR_ROLE | medium | high | Same multi-source mitigation + dispute / override mechanism in next contract version. |
| Compromised CALIBRATOR → arbitrary multiplier curve | CALIBRATOR_ROLE | medium | high | Multisig DEFAULT_ADMIN + `ScoreCurveUpdated` event monitored. |
| UPGRADER compromise → swap impl, mute reads or rewrite logic | UUPS | low | catastrophic | UPGRADER_ROLE separated + multisig 4-of-7 mandated before mainnet. |
| Front-running `grantRole(ATTESTOR)` to insert malicious attestor | mempool | low | critical | DEFAULT_ADMIN_ROLE on multisig; role grants emit auditable events. |

## DREAD scoring

| Threat | D | R | E | A | D | Total |
|---|---|---|---|---|---|---|
| Compromised ATTESTOR → mass false scores | 10 | 5 | 6 | 9 | 7 | **37** |
| UPGRADER compromise via single-sig | 10 | 3 | 5 | 9 | 8 | **35** |
| UUPS storage collision | 9 | 4 | 6 | 9 | 7 | **35** |
| Storage growth DoS over years | 5 | 9 | 7 | 5 | 5 | **31** |
| Compromised CALIBRATOR → bad curve | 7 | 5 | 6 | 7 | 6 | **31** |

Top risk: **compromised ATTESTOR** — the score is the product. Mitigation: insurer-side aggregation across N attestors + dispute mechanism (Phase 5 contract upgrade).

## Invariants we WANT external audit to formally verify

1. **Append-only history**: `attestationCount(vehicleDid)` is monotonically non-decreasing.
2. **Score bounds**: every stored attestation has `0 ≤ score ≤ MAX_SCORE`.
3. **Multiplier monotonic in score**: `priceMultiplierBps` is monotonically non-decreasing in `score` when `ceilingMultiplierBps >= floorMultiplierBps`.
4. **Multiplier bounded**: `floorMultiplierBps ≤ priceMultiplierBps(any) ≤ ceilingMultiplierBps` for any non-empty attestation.
5. **No state mutation outside `attest`, `recalibrate`, `setMaxAttestationAge`, role admin, pause**.
6. **No fund movement** (`address(this).balance == 0` always).

## Open issues for the audit firm

1. Should `attest()` require a per-`vehicleDid` attestor whitelist (not just role-wide ATTESTOR_ROLE)? Lean no Phase 1; revisit if compromise surface justifies.
2. Should we add a `disputeAttestation(vehicleDid, evidenceHash)` function for fleet operators to challenge scores? Phase 5 enhancement; not in scope for V1.
3. Should the `score` be quantised (step of 5) to reduce information leakage? No; insurance models need full granularity.
4. Echidna invariant run on append-only + multiplier monotonicity — recommend.
5. Should `setMaxAttestationAge` enforce a min/max window (e.g. 60s..30d) to prevent admin from setting it to 1 second (DoS) or `type(uint64).max` (effectively no staleness)? Recommend yes.

## Cross-references

- `AUDIT_CHECKLIST.md`
- `SECURITY.md`
- `threat-models/CredentialRevocationRegistry.STRIDE.md`
- `threat-models/HighRiskCommandVault.STRIDE.md`

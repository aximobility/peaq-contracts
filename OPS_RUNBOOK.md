# OPS_RUNBOOK.md - peaq-contracts production operations

> Day-2 procedures: incident response, key rotation, role hygiene, upgrades, multisig setup. Read once; refer to during incidents. Pair with `AGUNG_DEPLOY.md` for first-deploy and `AUDIT_CHECKLIST.md` for pre-engagement hardening.

---

## Roles + who holds what

| Role | Identity (recommended) | What it can do | Rotation cadence |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` (Registry/Oracle/Vault) | Safe multisig 4-of-7 | Grant/revoke any other role, pause, unpause | Quarterly drill, never compromised |
| `UPGRADER_ROLE` (Registry/Oracle) | Same Safe multisig | UUPS upgrade implementation | Per-upgrade |
| `PAUSER_ROLE` (all 3) | Same Safe multisig OR Brian's hardware wallet for fast response | Emergency pause | Per-incident |
| `ISSUER_ROLE` (Registry) | AXI cloud convex EOA (KMS-managed) | Revoke / batch-revoke credentials | Auto-rotated by `rotateStaleSecrets` cron (90 days) |
| `ATTESTOR_ROLE` (Oracle) | AXI atlas-harness EOA (KMS-managed) | Publish risk attestations | Same as above |
| `CALIBRATOR_ROLE` (Oracle) | Risk-team multisig 2-of-3 | Update score curve, max age | Per-recalibration |
| `PROPOSER_ROLE` (Vault) | AXI cloud convex EOA | Propose K-of-M commands | Same as ISSUER |
| `APPROVER_ROLE` (Vault) | K named operators with hardware wallets | Approve commands | Per-personnel-change |
| `EXECUTOR_ROLE` (Vault) | AXI atlas-harness EOA | Execute approved commands | Same as ATTESTOR |

## Multisig setup (one-time, before mainnet)

1. Deploy a Safe (`https://safe.global`) on peaq mainnet (chain 3338).
2. Add 7 signers (founders + ops leads + tech lead). Set threshold = 4.
3. Transfer DEFAULT_ADMIN_ROLE for all three contracts to the Safe address:
   ```bash
   cast send $REGISTRY_PROXY "grantRole(bytes32,address)" \
     0x0000000000000000000000000000000000000000000000000000000000000000 $SAFE_ADDR \
     --private-key $CURRENT_ADMIN_KEY --rpc-url mainnet
   cast send $REGISTRY_PROXY "renounceRole(bytes32,address)" \
     0x0000000000000000000000000000000000000000000000000000000000000000 $CURRENT_ADMIN_ADDR \
     --private-key $CURRENT_ADMIN_KEY --rpc-url mainnet
   ```
   (Repeat for `$ORACLE_PROXY` + `$VAULT`. Repeat for UPGRADER_ROLE + PAUSER_ROLE.)
4. Verify single source of admin via `cast call`:
   ```bash
   cast call $REGISTRY_PROXY "hasRole(bytes32,address)(bool)" \
     0x0000... $SAFE_ADDR
   # Expect: true
   cast call $REGISTRY_PROXY "hasRole(bytes32,address)(bool)" \
     0x0000... $CURRENT_ADMIN_ADDR
   # Expect: false
   ```

## Incident: suspected key compromise

Trigger: ISSUER, ATTESTOR, PROPOSER, EXECUTOR or APPROVER key thought to be exposed.

**Within 5 minutes:**
1. Pause the affected contract from PAUSER hardware wallet (no multisig delay):
   ```bash
   cast send $AFFECTED_CONTRACT "pause()" --private-key $PAUSER_KEY --rpc-url mainnet
   ```
2. Revoke the compromised role from a multisig signer:
   ```bash
   cast send $AFFECTED_CONTRACT "revokeRole(bytes32,address)" $ROLE_ID $LEAKED_ADDR \
     --private-key $SAFE_SIGNER_KEY --rpc-url mainnet
   # Then collect 3 more signatures via Safe UI to execute.
   ```
3. Rotate the secret in AWS Secrets Manager (replaces the env-served key for the next ECS deploy):
   ```bash
   aws secretsmanager put-secret-value --secret-id axi/peaq/evm-private-key --secret-string 0x...
   ```

**Within 1 hour:**
4. Audit on-chain history of the leaked address for unauthorised tx:
   ```bash
   cast logs --address $AFFECTED_CONTRACT --from-block <last_known_clean> \
     --rpc-url mainnet | grep -i $LEAKED_ADDR
   ```
5. Unpause from multisig once new role-holder is wired:
   ```bash
   cast send $AFFECTED_CONTRACT "unpause()" --private-key $SAFE_SIGNER_KEY --rpc-url mainnet
   ```
6. Postmortem: `RISK_REGISTER.md` entry with timeline, blast radius, fix.

## Incident: Oracle bad attestation

Trigger: ATL agent published an obviously wrong score (e.g. 0 for a vehicle with multiple harshBrake events) due to bug or compromised attestor.

**Within 1 hour:**
1. Pause the Oracle from PAUSER:
   ```bash
   cast send $ORACLE_PROXY "pause()" --private-key $PAUSER_KEY --rpc-url mainnet
   ```
2. Revoke ATTESTOR_ROLE from the offending address (multisig).
3. Investigate root cause: bug in `RiskAttestationAgent` scoring? Compromised key? RPC poisoning?
4. Override: there is no on-chain unattest. The next attestation supersedes; insurers reading `riskScore()` get the latest. Ship a new attestation from a fresh ATTESTOR EOA with the correct score.
5. Notify any insurer that priced a policy off the bad number (they hold the policy contract; payout depends on their contract terms).

## Incident: Vault command compromise

Trigger: A command got executed that shouldn't have (e.g. wrong vehicle immobilised).

**Within 5 minutes:**
1. Pause Vault to halt any in-flight commands:
   ```bash
   cast send $VAULT "pause()" --private-key $PAUSER_KEY --rpc-url mainnet
   ```
2. Identify executed-but-wrong command via `CommandExecuted` events:
   ```bash
   cast logs --address $VAULT --from-block <recent> --rpc-url mainnet
   ```
3. The on-chain record cannot be undone. Reverse the off-chain effect via the affected service:
   - Wrong vehicle immobilised → physical un-immobilise via OBD relay or service truck
   - Wrong fund movement → file claim with custodian / counterparty
4. Postmortem: which approver(s) signed? Were they coerced or compromised? Rotate APPROVER_ROLE for all questionable signers.

## Routine: monthly role audit

```bash
# Print every role-holder for each contract
for contract in $REGISTRY_PROXY $ORACLE_PROXY $VAULT; do
  for role in DEFAULT_ADMIN_ROLE PAUSER_ROLE; do
    echo "$contract $role:"
    cast call $contract "getRoleMemberCount(bytes32)(uint256)" $(cast keccak $role)
  done
done
```

Reconcile against the multisig signer roster. Any unexpected address → investigate immediately.

## Routine: upgrade procedure (UUPS, Registry + Oracle only)

1. Author + audit the new implementation in a feature branch
2. Deploy ONLY the new implementation (proxy stays):
   ```bash
   forge create --rpc-url mainnet --private-key $UPGRADER_KEY \
     src/CredentialRevocationRegistryV2.sol:CredentialRevocationRegistryV2
   ```
3. Verify storage layout compat:
   ```bash
   forge inspect CredentialRevocationRegistry storage-layout > before.json
   forge inspect CredentialRevocationRegistryV2 storage-layout > after.json
   diff before.json after.json
   # Acceptable change: appended new fields. UNACCEPTABLE: any reorder, removal, or type change of existing fields.
   ```
4. Run slither upgradeability check:
   ```bash
   slither-check-upgradeability . CredentialRevocationRegistryV2 --proxy-name CredentialRevocationRegistry
   ```
5. From multisig, call `upgradeToAndCall` on the proxy with the new impl address:
   ```bash
   cast send $REGISTRY_PROXY "upgradeToAndCall(address,bytes)" $NEW_IMPL_ADDR 0x \
     --private-key $SAFE_SIGNER_KEY --rpc-url mainnet
   ```
6. Post-upgrade verification:
   ```bash
   make verify-mainnet
   ```
7. Tag the commit + log in `UPGRADES.md`.

## Routine: recalibrate Oracle score curve

Calibration changes the bps curve without invalidating prior attestations.
```bash
cast send $ORACLE_PROXY "recalibrate(uint16,uint16)" 7500 14000 \
  --private-key $CALIBRATOR_KEY --rpc-url mainnet
```
Effect: from this tx onward, every `priceMultiplierBps()` call uses the new curve. Old `RiskAttested` events still cite the original score; the multiplier on those scores recalculates against the new curve.

## Routine: monthly drill

Once a month, run the full incident response from staging (agung) to keep muscle memory:
1. Pause a contract
2. Rotate a role
3. Verify the platform handles "contract paused" cleanly (action handlers should return `{ok: false, reason: "paused"}`)
4. Unpause
5. Document in `DRILL_LOG.md`

## Reference: cast snippets

```bash
# Get role bytes32
cast keccak ISSUER_ROLE
# Check if address has role
cast call $CONTRACT "hasRole(bytes32,address)(bool)" $ROLE $ADDR
# Read latest block
cast block-number --rpc-url mainnet
# Read tx receipt
cast receipt $TX_HASH --rpc-url mainnet
# Decode revert reason
cast 4byte-decode $ERROR_DATA
# Watch logs
cast logs --address $CONTRACT --rpc-url mainnet
```

---

## Required reading before any of the above

- `AGUNG_DEPLOY.md` — first-deploy procedure
- `AUDIT_CHECKLIST.md` — pre-engagement hardening
- `aximobility/platform/AUDIT_PLAN.md` — engagement scope + post-audit gate
- `aximobility/platform/DEPLOYMENT_RUNBOOK.md` — how the contract addresses get into AWS Secrets Manager

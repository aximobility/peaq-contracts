// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CredentialRevocationRegistry} from "../src/CredentialRevocationRegistry.sol";
import {InsuranceRiskOracle} from "../src/InsuranceRiskOracle.sol";
import {HighRiskCommandVault} from "../src/HighRiskCommandVault.sol";

/// @notice Post-deploy verification: reads the three contracts at the addresses
///         passed via env vars + asserts the expected role configuration.
///
/// Usage:
///   forge script script/Verify.s.sol:Verify --rpc-url agung
contract Verify is Script {
    function run() external view {
        address registry = vm.envAddress("REGISTRY_PROXY");
        address oracle = vm.envAddress("ORACLE_PROXY");
        address vault = vm.envAddress("VAULT");
        address admin = vm.envAddress("ADMIN");

        CredentialRevocationRegistry reg = CredentialRevocationRegistry(registry);
        InsuranceRiskOracle ora = InsuranceRiskOracle(oracle);
        HighRiskCommandVault vlt = HighRiskCommandVault(vault);

        require(reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), admin), "Registry admin missing");
        require(ora.hasRole(ora.DEFAULT_ADMIN_ROLE(), admin), "Oracle admin missing");
        require(vlt.hasRole(vlt.DEFAULT_ADMIN_ROLE(), admin), "Vault admin missing");

        console2.log("=== Verification ===");
        console2.log("Registry totalRevoked:", reg.totalRevoked());
        console2.log("Oracle floor bps:     ", ora.floorMultiplierBps());
        console2.log("Oracle ceiling bps:   ", ora.ceilingMultiplierBps());
        console2.log("Vault MIN_EXPIRY:     ", vlt.MIN_EXPIRY_WINDOW());
        console2.log("Vault MAX_EXPIRY:     ", vlt.MAX_EXPIRY_WINDOW());
        console2.log("All contracts healthy at admin:", admin);
    }
}

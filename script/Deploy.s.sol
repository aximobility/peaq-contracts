// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CredentialRevocationRegistry} from "../src/CredentialRevocationRegistry.sol";
import {InsuranceRiskOracle} from "../src/InsuranceRiskOracle.sol";
import {HighRiskCommandVault} from "../src/HighRiskCommandVault.sol";

/// @notice Deploys the three Tier-1 AXI contracts:
///         1. CredentialRevocationRegistry (UUPS proxy)
///         2. InsuranceRiskOracle (UUPS proxy)
///         3. HighRiskCommandVault (immutable)
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url agung --broadcast --verify
///   forge script script/Deploy.s.sol:Deploy --rpc-url mainnet --broadcast --verify --slow
///
/// Required env (.env):
///   DEPLOYER_PRIVATE_KEY  (required, 0x-prefixed)
///   ADMIN                 (required, 0x address)
///   ISSUERS               (comma-separated 0x addresses)
///   ATTESTORS             (comma-separated 0x addresses)
///   APPROVERS             (comma-separated 0x addresses)
contract Deploy is Script {
    struct DeployedAddresses {
        address registryImpl;
        address registryProxy;
        address oracleImpl;
        address oracleProxy;
        address vault;
    }

    function run() external returns (DeployedAddresses memory out) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN");
        address[] memory issuers = _envAddresses("ISSUERS");
        address[] memory attestors = _envAddresses("ATTESTORS");
        address[] memory approvers = _envAddresses("APPROVERS");

        require(admin != address(0), "ADMIN must be set");
        require(issuers.length != 0, "At least one ISSUER required");
        require(attestors.length != 0, "At least one ATTESTOR required");
        require(approvers.length >= 2, "At least two APPROVERS required for K-of-M");

        vm.startBroadcast(pk);

        // 1. CredentialRevocationRegistry (UUPS)
        CredentialRevocationRegistry regImpl = new CredentialRevocationRegistry();
        bytes memory regInit = abi.encodeCall(CredentialRevocationRegistry.initialize, (admin, issuers));
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        out.registryImpl = address(regImpl);
        out.registryProxy = address(regProxy);

        // 2. InsuranceRiskOracle (UUPS)
        // Default curve: 70% floor (-30% premium at score=0) → 150% ceiling (+50% at MAX_SCORE).
        // Default staleness window: 7 days. Recalibrate later via CALIBRATOR_ROLE.
        InsuranceRiskOracle oracleImpl = new InsuranceRiskOracle();
        bytes memory oracleInit = abi.encodeCall(
            InsuranceRiskOracle.initialize, (admin, attestors, uint16(7000), uint16(15_000), uint64(7 days))
        );
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), oracleInit);
        out.oracleImpl = address(oracleImpl);
        out.oracleProxy = address(oracleProxy);

        // 3. HighRiskCommandVault (immutable)
        // Proposer set defaults to admin alone; admin can grant additional via authoriseProposer.
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        HighRiskCommandVault vault = new HighRiskCommandVault(admin, proposers, approvers);
        out.vault = address(vault);

        vm.stopBroadcast();

        console2.log("=== AXI peaq-contracts deployment ===");
        console2.log("CredentialRevocationRegistry impl: ", out.registryImpl);
        console2.log("CredentialRevocationRegistry proxy:", out.registryProxy);
        console2.log("InsuranceRiskOracle impl:          ", out.oracleImpl);
        console2.log("InsuranceRiskOracle proxy:         ", out.oracleProxy);
        console2.log("HighRiskCommandVault:              ", out.vault);
        console2.log("Admin (DEFAULT_ADMIN_ROLE):        ", admin);
    }

    /// @dev Parse comma-separated env var into address[].
    function _envAddresses(string memory key) internal view returns (address[] memory out) {
        string memory raw = vm.envOr(key, string(""));
        if (bytes(raw).length == 0) return new address[](0);
        return vm.envAddress(key, ",");
    }
}

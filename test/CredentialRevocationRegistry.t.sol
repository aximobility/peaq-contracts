// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CredentialRevocationRegistry} from "../src/CredentialRevocationRegistry.sol";
import {ICredentialRevocationRegistry} from "../src/interfaces/ICredentialRevocationRegistry.sol";

contract CredentialRevocationRegistryTest is Test {
    CredentialRevocationRegistry internal reg;
    address internal admin = address(0xA1);
    address internal issuer = address(0xB1);
    address internal issuer2 = address(0xB2);
    address internal random = address(0xC1);

    bytes32 internal constant CRED_A = keccak256("cred-A");
    bytes32 internal constant CRED_B = keccak256("cred-B");
    bytes32 internal constant CRED_C = keccak256("cred-C");
    bytes32 internal constant REASON_REVOKED = keccak256("DRIVER_TERMINATED");
    bytes32 internal constant REASON_KEY_COMP = keccak256("ISSUER_KEY_COMPROMISED");

    function setUp() public {
        CredentialRevocationRegistry impl = new CredentialRevocationRegistry();
        address[] memory issuers = new address[](1);
        issuers[0] = issuer;
        bytes memory init = abi.encodeCall(CredentialRevocationRegistry.initialize, (admin, issuers));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        reg = CredentialRevocationRegistry(address(proxy));
    }

    // ---- Initialization ----

    function test_Init_GrantsRolesToAdmin() public view {
        assertTrue(reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(reg.hasRole(reg.PAUSER_ROLE(), admin));
        assertTrue(reg.hasRole(reg.UPGRADER_ROLE(), admin));
        assertTrue(reg.hasRole(reg.ISSUER_ROLE(), issuer));
    }

    function test_Init_RejectsReinitialise() public {
        address[] memory issuers = new address[](0);
        vm.expectRevert();
        reg.initialize(admin, issuers);
    }

    // ---- Revoke (single) ----

    function test_Revoke_HappyPath() public {
        vm.prank(issuer);
        vm.expectEmit(true, true, false, true);
        emit ICredentialRevocationRegistry.CredentialRevoked(CRED_A, issuer, REASON_REVOKED);
        reg.revoke(CRED_A, REASON_REVOKED);

        assertTrue(reg.isRevoked(CRED_A));
        assertEq(reg.totalRevoked(), 1);

        ICredentialRevocationRegistry.RevocationRecord memory rec = reg.whyRevoked(CRED_A);
        assertEq(rec.revokedAt, uint64(block.timestamp));
        assertEq(rec.reasonCode, REASON_REVOKED);
        assertEq(rec.revokedBy, issuer);
    }

    function test_Revoke_RejectsEmptyHash() public {
        vm.prank(issuer);
        vm.expectRevert(ICredentialRevocationRegistry.EmptyCredentialHash.selector);
        reg.revoke(bytes32(0), REASON_REVOKED);
    }

    function test_Revoke_RejectsDoubleRevoke() public {
        vm.prank(issuer);
        reg.revoke(CRED_A, REASON_REVOKED);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ICredentialRevocationRegistry.AlreadyRevoked.selector, CRED_A));
        reg.revoke(CRED_A, REASON_REVOKED);
    }

    function test_Revoke_RejectsUnauthorisedCaller() public {
        vm.prank(random);
        vm.expectRevert();
        reg.revoke(CRED_A, REASON_REVOKED);
    }

    // ---- RevokeBatch ----

    function test_RevokeBatch_RevokesAllNew() public {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = CRED_A;
        hashes[1] = CRED_B;
        hashes[2] = CRED_C;

        vm.prank(issuer);
        reg.revokeBatch(hashes, REASON_KEY_COMP);

        assertTrue(reg.isRevoked(CRED_A));
        assertTrue(reg.isRevoked(CRED_B));
        assertTrue(reg.isRevoked(CRED_C));
        assertEq(reg.totalRevoked(), 3);
    }

    function test_RevokeBatch_SkipsAlreadyRevoked() public {
        vm.prank(issuer);
        reg.revoke(CRED_B, REASON_REVOKED);

        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = CRED_A;
        hashes[1] = CRED_B; // skipped
        hashes[2] = CRED_C;

        vm.prank(issuer);
        reg.revokeBatch(hashes, REASON_KEY_COMP);

        assertEq(reg.totalRevoked(), 3);
        assertEq(reg.whyRevoked(CRED_B).reasonCode, REASON_REVOKED, "earlier reason preserved");
    }

    function test_RevokeBatch_SkipsEmptyHashes() public {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = bytes32(0);
        hashes[1] = CRED_A;

        vm.prank(issuer);
        reg.revokeBatch(hashes, REASON_KEY_COMP);

        assertEq(reg.totalRevoked(), 1);
        assertTrue(reg.isRevoked(CRED_A));
    }

    // ---- Unrevoke ----

    function test_Unrevoke_AdminOnly() public {
        vm.prank(issuer);
        reg.revoke(CRED_A, REASON_REVOKED);

        vm.prank(issuer);
        vm.expectRevert();
        reg.unrevoke(CRED_A);

        vm.prank(admin);
        reg.unrevoke(CRED_A);
        assertFalse(reg.isRevoked(CRED_A));
        assertEq(reg.totalRevoked(), 0);
    }

    function test_Unrevoke_RejectsIfNotRevoked() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICredentialRevocationRegistry.NotRevoked.selector, CRED_A));
        reg.unrevoke(CRED_A);
    }

    // ---- Issuer management ----

    function test_AuthoriseIssuer() public {
        vm.prank(admin);
        reg.authoriseIssuer(issuer2);
        assertTrue(reg.hasRole(reg.ISSUER_ROLE(), issuer2));

        vm.prank(issuer2);
        reg.revoke(CRED_A, REASON_REVOKED);
        assertTrue(reg.isRevoked(CRED_A));
    }

    function test_RevokeIssuer() public {
        vm.prank(admin);
        reg.revokeIssuer(issuer);

        vm.prank(issuer);
        vm.expectRevert();
        reg.revoke(CRED_A, REASON_REVOKED);
    }

    // ---- Pause ----

    function test_Pause_BlocksWrites() public {
        vm.prank(admin);
        reg.pause();

        vm.prank(issuer);
        vm.expectRevert();
        reg.revoke(CRED_A, REASON_REVOKED);
    }

    function test_Pause_AllowsReads() public {
        vm.prank(issuer);
        reg.revoke(CRED_A, REASON_REVOKED);
        vm.prank(admin);
        reg.pause();

        assertTrue(reg.isRevoked(CRED_A));
    }

    // ---- Fuzz ----

    function testFuzz_Revoke_OnlyAffectsTargetHash(bytes32 a, bytes32 b) public {
        vm.assume(a != bytes32(0) && b != bytes32(0) && a != b);
        vm.prank(issuer);
        reg.revoke(a, REASON_REVOKED);

        assertTrue(reg.isRevoked(a));
        assertFalse(reg.isRevoked(b));
    }
}

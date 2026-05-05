// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HighRiskCommandVault} from "../src/HighRiskCommandVault.sol";
import {IHighRiskCommandVault} from "../src/interfaces/IHighRiskCommandVault.sol";

contract HighRiskCommandVaultTest is Test {
    HighRiskCommandVault internal vault;
    address internal admin = address(0xA1);
    address internal proposer = address(0xB1);
    address internal approverA = address(0xC1);
    address internal approverB = address(0xC2);
    address internal approverC = address(0xC3);
    address internal executor = address(0xD1);
    address internal random = address(0xE1);

    bytes32 internal constant CMD_TYPE = keccak256("vehicle.immobilize");
    bytes32 internal constant TARGET_DID = keccak256("did:peaq:vehicleA");

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory approvers = new address[](3);
        approvers[0] = approverA;
        approvers[1] = approverB;
        approvers[2] = approverC;
        vault = new HighRiskCommandVault(admin, proposers, approvers);

        vm.prank(admin);
        vault.authoriseExecutor(executor);
    }

    // ---- Helpers ----

    function _propose(uint8 k, uint8 m, bytes memory payload) internal returns (bytes32 id) {
        vm.prank(proposer);
        id = vault.propose(CMD_TYPE, TARGET_DID, payload, k, m, uint64(block.timestamp + 1 hours));
    }

    // ---- Propose ----

    function test_Propose_HappyPath() public {
        bytes memory payload = abi.encode(uint256(1));
        vm.prank(proposer);
        vm.expectEmit(true, true, true, true);
        emit IHighRiskCommandVault.CommandProposed(
            keccak256(
                abi.encode(
                    CMD_TYPE,
                    TARGET_DID,
                    keccak256(payload),
                    uint8(2),
                    uint8(3),
                    uint64(block.timestamp),
                    proposer
                )
            ),
            CMD_TYPE,
            TARGET_DID,
            proposer,
            uint8(2),
            uint8(3),
            uint64(block.timestamp + 1 hours)
        );
        bytes32 id = vault.propose(CMD_TYPE, TARGET_DID, payload, 2, 3, uint64(block.timestamp + 1 hours));

        IHighRiskCommandVault.Command memory cmd = vault.command(id);
        assertEq(uint8(cmd.status), uint8(IHighRiskCommandVault.Status.Proposed));
        assertEq(cmd.thresholdK, 2);
        assertEq(cmd.totalApprovers, 3);
        assertEq(cmd.proposer, proposer);
        assertEq(cmd.payloadHash, keccak256(payload));
    }

    function test_Propose_RejectsInvalidThreshold() public {
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IHighRiskCommandVault.InvalidThreshold.selector, uint8(0), uint8(3))
        );
        vault.propose(CMD_TYPE, TARGET_DID, "x", 0, 3, uint64(block.timestamp + 1 hours));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IHighRiskCommandVault.InvalidThreshold.selector, uint8(4), uint8(3))
        );
        vault.propose(CMD_TYPE, TARGET_DID, "x", 4, 3, uint64(block.timestamp + 1 hours));
    }

    function test_Propose_RejectsInvalidExpiry() public {
        vm.prank(proposer);
        vm.expectRevert();
        vault.propose(CMD_TYPE, TARGET_DID, "x", 2, 3, uint64(block.timestamp + 5)); // < MIN_EXPIRY_WINDOW

        vm.prank(proposer);
        vm.expectRevert();
        vault.propose(CMD_TYPE, TARGET_DID, "x", 2, 3, uint64(block.timestamp + 31 days));
    }

    function test_Propose_RejectsUnauthorised() public {
        vm.prank(random);
        vm.expectRevert();
        vault.propose(CMD_TYPE, TARGET_DID, "x", 2, 3, uint64(block.timestamp + 1 hours));
    }

    // ---- Approve ----

    function test_Approve_AccumulatesUntilThresholdReached() public {
        bytes memory payload = abi.encode(uint256(1));
        bytes32 id = _propose(2, 3, payload);

        vm.prank(approverA);
        vault.approve(id);
        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Proposed));
        assertEq(vault.command(id).approvalCount, 1);

        vm.prank(approverB);
        vault.approve(id);
        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Approved));
        assertEq(vault.command(id).approvalCount, 2);
    }

    function test_Approve_RejectsDoubleApproveBySameAddress() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(approverA);
        vault.approve(id);
        vm.prank(approverA);
        vm.expectRevert(abi.encodeWithSelector(IHighRiskCommandVault.AlreadyApproved.selector, id, approverA));
        vault.approve(id);
    }

    function test_Approve_RejectsAfterExpiry() public {
        bytes32 id = _propose(2, 3, "x");
        uint64 exp = vault.command(id).expiresAt;
        vm.warp(exp + 1);
        vm.prank(approverA);
        vm.expectRevert(abi.encodeWithSelector(IHighRiskCommandVault.CommandExpired.selector, id, exp));
        vault.approve(id);
        // Status stays Proposed because the revert reverts the write. markExpired()
        // is the explicit GC path that flips the visible state.
        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Proposed));

        vault.markExpired(id);
        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Expired));
    }

    function test_Approve_RejectsUnauthorisedAddress() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(random);
        vm.expectRevert();
        vault.approve(id);
    }

    // ---- Execute ----

    function test_Execute_HappyPath() public {
        bytes memory payload = abi.encode(uint256(42), "remote-immobilize");
        bytes32 id = _propose(2, 3, payload);
        vm.prank(approverA);
        vault.approve(id);
        vm.prank(approverB);
        vault.approve(id);

        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit IHighRiskCommandVault.CommandExecuted(id, executor, payload);
        vault.execute(id, payload);

        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Executed));
    }

    function test_Execute_RejectsPayloadHashMismatch() public {
        bytes memory payload = abi.encode(uint256(42));
        bytes32 id = _propose(2, 3, payload);
        vm.prank(approverA);
        vault.approve(id);
        vm.prank(approverB);
        vault.approve(id);

        bytes memory tampered = abi.encode(uint256(43));
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHighRiskCommandVault.PayloadHashMismatch.selector, keccak256(payload), keccak256(tampered)
            )
        );
        vault.execute(id, tampered);
    }

    function test_Execute_RejectsBeforeApproval() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHighRiskCommandVault.CommandNotApproved.selector, id, IHighRiskCommandVault.Status.Proposed
            )
        );
        vault.execute(id, "x");
    }

    function test_Execute_RejectsUnauthorisedExecutor() public {
        bytes memory payload = "x";
        bytes32 id = _propose(2, 3, payload);
        vm.prank(approverA);
        vault.approve(id);
        vm.prank(approverB);
        vault.approve(id);

        vm.prank(random);
        vm.expectRevert();
        vault.execute(id, payload);
    }

    // ---- Cancel ----

    function test_Cancel_ByProposer() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(proposer);
        vault.cancel(id);
        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Cancelled));
    }

    function test_Cancel_ByAnyApprover() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(approverC);
        vault.cancel(id);
        assertEq(uint8(vault.command(id).status), uint8(IHighRiskCommandVault.Status.Cancelled));
    }

    function test_Cancel_RejectsAfterExecution() public {
        bytes memory payload = "x";
        bytes32 id = _propose(2, 3, payload);
        vm.prank(approverA);
        vault.approve(id);
        vm.prank(approverB);
        vault.approve(id);
        vm.prank(executor);
        vault.execute(id, payload);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHighRiskCommandVault.CommandNotProposed.selector, id, IHighRiskCommandVault.Status.Executed
            )
        );
        vault.cancel(id);
    }

    function test_Cancel_RejectsRandom() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(random);
        vm.expectRevert();
        vault.cancel(id);
    }

    // ---- Pause ----

    function test_Pause_BlocksAllStateChanges() public {
        bytes32 id = _propose(2, 3, "x");
        vm.prank(admin);
        vault.pause();

        vm.prank(proposer);
        vm.expectRevert();
        vault.propose(CMD_TYPE, TARGET_DID, "y", 2, 3, uint64(block.timestamp + 1 hours));

        vm.prank(approverA);
        vm.expectRevert();
        vault.approve(id);
    }

    // ---- Fuzz ----

    function testFuzz_PropuseAlwaysReturnsUniqueIds(bytes32 t1, bytes32 t2) public {
        vm.assume(t1 != t2);
        vm.startPrank(proposer);
        bytes32 id1 = vault.propose(CMD_TYPE, t1, "x", 2, 3, uint64(block.timestamp + 1 hours));
        bytes32 id2 = vault.propose(CMD_TYPE, t2, "x", 2, 3, uint64(block.timestamp + 1 hours));
        vm.stopPrank();
        assertTrue(id1 != id2);
    }
}

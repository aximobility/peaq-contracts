// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InsuranceRiskOracle} from "../src/InsuranceRiskOracle.sol";
import {IInsuranceRiskOracle} from "../src/interfaces/IInsuranceRiskOracle.sol";

contract InsuranceRiskOracleTest is Test {
    InsuranceRiskOracle internal oracle;
    address internal admin = address(0xA1);
    address internal attestor = address(0xB1);
    address internal random = address(0xC1);

    bytes32 internal constant VEH_A = keccak256("vehicle-A");
    bytes32 internal constant ROOT_A = keccak256("root-A");

    uint16 internal constant FLOOR_BPS = 7000;
    uint16 internal constant CEIL_BPS = 15_000;
    uint64 internal constant MAX_AGE = 7 days;

    function setUp() public {
        InsuranceRiskOracle impl = new InsuranceRiskOracle();
        address[] memory attestors = new address[](1);
        attestors[0] = attestor;
        bytes memory init =
            abi.encodeCall(InsuranceRiskOracle.initialize, (admin, attestors, FLOOR_BPS, CEIL_BPS, MAX_AGE));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        oracle = InsuranceRiskOracle(address(proxy));
    }

    // ---- Initialization ----

    function test_Init_AppliesCurve() public view {
        assertEq(oracle.floorMultiplierBps(), FLOOR_BPS);
        assertEq(oracle.ceilingMultiplierBps(), CEIL_BPS);
        assertEq(oracle.maxAttestationAgeSeconds(), MAX_AGE);
        assertTrue(oracle.hasRole(oracle.ATTESTOR_ROLE(), attestor));
    }

    // ---- Attest ----

    function test_Attest_HappyPath() public {
        vm.prank(attestor);
        vm.expectEmit(true, false, false, true);
        emit IInsuranceRiskOracle.RiskAttested(VEH_A, 420, ROOT_A, 1850, attestor);
        oracle.attest(VEH_A, 420, ROOT_A, 1850);

        (uint16 score, uint64 attestedAt) = oracle.riskScore(VEH_A);
        assertEq(score, 420);
        assertEq(attestedAt, uint64(block.timestamp));

        IInsuranceRiskOracle.RiskAttestation memory rec = oracle.latestAttestation(VEH_A);
        assertEq(rec.anchorRoot, ROOT_A);
        assertEq(rec.sampleSizeKm, 1850);
        assertEq(rec.attestor, attestor);
    }

    function test_Attest_RejectsScoreOverMax() public {
        vm.prank(attestor);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceRiskOracle.InvalidScore.selector, 1001, 1000));
        oracle.attest(VEH_A, 1001, ROOT_A, 1850);
    }

    function test_Attest_RejectsEmptyVehicleDid() public {
        vm.prank(attestor);
        vm.expectRevert(IInsuranceRiskOracle.EmptyVehicleDid.selector);
        oracle.attest(bytes32(0), 420, ROOT_A, 1850);
    }

    function test_Attest_RejectsEmptyAnchorRoot() public {
        vm.prank(attestor);
        vm.expectRevert(IInsuranceRiskOracle.EmptyAnchorRoot.selector);
        oracle.attest(VEH_A, 420, bytes32(0), 1850);
    }

    function test_Attest_RejectsUnauthorisedCaller() public {
        vm.prank(random);
        vm.expectRevert();
        oracle.attest(VEH_A, 420, ROOT_A, 1850);
    }

    // ---- History ----

    function test_History_PreservesAllAttestations() public {
        vm.startPrank(attestor);
        oracle.attest(VEH_A, 420, ROOT_A, 1850);
        vm.warp(block.timestamp + 1 days);
        oracle.attest(VEH_A, 380, keccak256("root-2"), 2100);
        vm.warp(block.timestamp + 1 days);
        oracle.attest(VEH_A, 350, keccak256("root-3"), 2500);
        vm.stopPrank();

        assertEq(oracle.attestationCount(VEH_A), 3);
        assertEq(oracle.attestationAt(VEH_A, 0).score, 420);
        assertEq(oracle.attestationAt(VEH_A, 2).score, 350);
        (uint16 latest,) = oracle.riskScore(VEH_A);
        assertEq(latest, 350);
    }

    // ---- Stale ----

    function test_RiskScore_RevertsWhenStale() public {
        vm.prank(attestor);
        oracle.attest(VEH_A, 420, ROOT_A, 1850);

        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInsuranceRiskOracle.AttestationTooStale.selector,
                uint64(block.timestamp - MAX_AGE - 1),
                MAX_AGE
            )
        );
        oracle.riskScore(VEH_A);
    }

    function test_RiskScore_RevertsWhenAbsent() public {
        vm.expectRevert(abi.encodeWithSelector(IInsuranceRiskOracle.NoAttestation.selector, VEH_A));
        oracle.riskScore(VEH_A);
    }

    // ---- Multiplier curve ----

    function test_Multiplier_AtScoreZero_EqualsFloor() public {
        vm.prank(attestor);
        oracle.attest(VEH_A, 0, ROOT_A, 1850);
        assertEq(oracle.priceMultiplierBps(VEH_A), FLOOR_BPS);
    }

    function test_Multiplier_AtMaxScore_EqualsCeiling() public {
        uint16 maxScore = oracle.MAX_SCORE();
        vm.prank(attestor);
        oracle.attest(VEH_A, maxScore, ROOT_A, 1850);
        assertEq(oracle.priceMultiplierBps(VEH_A), CEIL_BPS);
    }

    function test_Multiplier_AtMidScore_InterpolatesLinearly() public {
        vm.prank(attestor);
        oracle.attest(VEH_A, 500, ROOT_A, 1850);
        // floor 7000 + (15000-7000) * 500/1000 = 7000 + 4000 = 11000
        assertEq(oracle.priceMultiplierBps(VEH_A), 11_000);
    }

    // ---- Recalibrate ----

    function test_Recalibrate_UpdatesCurve() public {
        vm.prank(admin);
        oracle.recalibrate(8000, 14_000);
        assertEq(oracle.floorMultiplierBps(), 8000);
        assertEq(oracle.ceilingMultiplierBps(), 14_000);

        vm.prank(attestor);
        oracle.attest(VEH_A, 500, ROOT_A, 1850);
        // 8000 + (14000-8000) * 500/1000 = 11_000
        assertEq(oracle.priceMultiplierBps(VEH_A), 11_000);
    }

    function test_Recalibrate_RejectsUnauthorisedCaller() public {
        vm.prank(random);
        vm.expectRevert();
        oracle.recalibrate(8000, 14_000);
    }

    // ---- Pause ----

    function test_Pause_BlocksAttestations() public {
        vm.prank(admin);
        oracle.pause();
        vm.prank(attestor);
        vm.expectRevert();
        oracle.attest(VEH_A, 420, ROOT_A, 1850);
    }

    // ---- Fuzz ----

    function testFuzz_Multiplier_MonotonicInScore(uint16 lo, uint16 hi) public {
        vm.assume(lo < hi && hi <= oracle.MAX_SCORE());
        vm.startPrank(attestor);
        oracle.attest(VEH_A, lo, ROOT_A, 1850);
        uint16 mLow = oracle.priceMultiplierBps(VEH_A);
        oracle.attest(VEH_A, hi, ROOT_A, 1850);
        uint16 mHigh = oracle.priceMultiplierBps(VEH_A);
        vm.stopPrank();
        assertGe(mHigh, mLow);
    }

    function testFuzz_Multiplier_NeverExceedsCeiling(uint16 score) public {
        uint16 maxScore = oracle.MAX_SCORE();
        score = uint16(bound(score, 0, maxScore));
        vm.prank(attestor);
        oracle.attest(VEH_A, score, ROOT_A, 1850);
        assertLe(oracle.priceMultiplierBps(VEH_A), CEIL_BPS);
        assertGe(oracle.priceMultiplierBps(VEH_A), FLOOR_BPS);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { CLAWDdca } from "../contracts/CLAWDdca.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSwapRouter } from "./mocks/MockSwapRouter.sol";
import { MockQuoter } from "./mocks/MockQuoter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Reentrancy attacker disguised as a CLAWD recipient — no longer used directly; reentrancy is
/// exercised via MockSwapRouter.setReentrancy().
contract CLAWDdcaTest is Test {
    // Hardcoded production addresses (must match CLAWDdca.sol constants).
    address constant CLAWD_ADDR = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
    address constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ROUTER_ADDR = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant QUOTER_ADDR = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    CLAWDdca dca;
    address constant OWNER = address(0xA11CE);
    address constant ALICE = address(0xB0B0);
    address constant BOB = address(0xCAFE);
    address constant KEEPER = address(0xBEEF);

    // 1 USDC (6 dec) -> 100 CLAWD (18 dec). 1e6 USDC -> 100e18 CLAWD.
    // rate = 100e18 / 1e6 = 1e14 (numerator)/(denominator=1).
    uint256 constant RATE_NUM = 100e18;
    uint256 constant RATE_DENOM = 1e6;

    // v2 fee constants (must match CLAWDdca.sol)
    uint256 constant KEEPER_FEE_BPS = 20; // 0.20%
    uint256 constant PROTOCOL_FEE_BPS = 10; // 0.10%
    uint256 constant BURN_FEE_BPS = 20; // 0.20%
    uint256 constant BPS_DENOM = 10_000;

    function setUp() public {
        // Deploy mock contracts then etch their runtime code to the hardcoded production addresses.
        MockERC20 usdcImpl = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 clawdImpl = new MockERC20("CLAWD", "CLAWD", 18);
        MockSwapRouter routerImpl = new MockSwapRouter(USDC_ADDR, CLAWD_ADDR, RATE_NUM, RATE_DENOM);
        MockQuoter quoterImpl = new MockQuoter(RATE_NUM, RATE_DENOM);

        vm.etch(USDC_ADDR, address(usdcImpl).code);
        vm.etch(CLAWD_ADDR, address(clawdImpl).code);
        vm.etch(ROUTER_ADDR, address(routerImpl).code);
        vm.etch(QUOTER_ADDR, address(quoterImpl).code);

        // Initialize router state (inputToken/outputToken/rate) at the etched address.
        // The MockSwapRouter constructor wrote the constructor's args to the impl's storage; etching only copies
        // runtime code, not storage. Re-init via direct calls.
        // Simplest path: store via a setter. Add inline by writing storage via vm.store.
        // Slot 0: inputToken; Slot 1: outputToken; Slot 2: rateNumerator; Slot 3: rateDenominator;
        // Slot 4: forceOutput; Slot 5: reentrancyTarget; Slot 6: reentrancyCalldata (bytes)
        vm.store(ROUTER_ADDR, bytes32(uint256(0)), bytes32(uint256(uint160(USDC_ADDR))));
        vm.store(ROUTER_ADDR, bytes32(uint256(1)), bytes32(uint256(uint160(CLAWD_ADDR))));
        vm.store(ROUTER_ADDR, bytes32(uint256(2)), bytes32(RATE_NUM));
        vm.store(ROUTER_ADDR, bytes32(uint256(3)), bytes32(RATE_DENOM));

        // MockQuoter slots: 0 = rateNumerator, 1 = rateDenominator
        vm.store(QUOTER_ADDR, bytes32(uint256(0)), bytes32(RATE_NUM));
        vm.store(QUOTER_ADDR, bytes32(uint256(1)), bytes32(RATE_DENOM));

        // Move to a sane timestamp so currentEpoch is well past 0.
        vm.warp(1_700_000_000); // late 2023; ~157407 epochs

        // Deploy the contract under test.
        dca = new CLAWDdca(OWNER);

        // Fund users with USDC.
        MockERC20(USDC_ADDR).mint(ALICE, 1_000_000e6); // 1M USDC
        MockERC20(USDC_ADDR).mint(BOB, 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _approveUsdc(address user, uint256 amount) internal {
        vm.prank(user);
        IERC20(USDC_ADDR).approve(address(dca), amount);
    }

    function _createPosition(address user, uint256 total, uint256 perSwap, uint256 epochs)
        internal
        returns (uint256 id)
    {
        _approveUsdc(user, total);
        vm.prank(user);
        id = dca.createPosition(total, perSwap, epochs);
    }

    function _readPosition(uint256 id)
        internal
        view
        returns (
            address pOwner,
            uint256 usdcBalance,
            uint256 clawdAccrued,
            uint256 amountPerSwap,
            uint256 intervalInEpochs,
            uint256 lastExecutedEpoch,
            uint256 slippageBps,
            bool active
        )
    {
        return dca.positions(id);
    }

    // -------------------------------------------------------------------------
    // Constructor / constants
    // -------------------------------------------------------------------------

    function test_Constructor_SetsOwnerAndPath() public view {
        assertEq(dca.owner(), OWNER);
        assertEq(dca.nextPositionId(), 1);
        bytes memory path = dca.swapPath();
        // Length: 20 + 3 + 20 + 3 + 20 = 66
        assertEq(path.length, 66);
    }

    function test_Constructor_RevertsZeroOwner() public {
        vm.expectRevert();
        new CLAWDdca(address(0));
    }

    // -------------------------------------------------------------------------
    // createPosition
    // -------------------------------------------------------------------------

    function test_CreatePosition_Happy() public {
        _approveUsdc(ALICE, 1000e6);
        vm.prank(ALICE);
        uint256 id = dca.createPosition(1000e6, 100e6, 1);
        assertEq(id, 1);

        (
            address pOwner,
            uint256 usdcBalance,
            uint256 clawdAccrued,
            uint256 amountPerSwap,
            uint256 intervalInEpochs,
            uint256 lastExecutedEpoch,
            uint256 slippageBps,
            bool active
        ) = _readPosition(id);
        assertEq(pOwner, ALICE);
        assertEq(usdcBalance, 1000e6);
        assertEq(clawdAccrued, 0);
        assertEq(amountPerSwap, 100e6);
        assertEq(intervalInEpochs, 1);
        assertEq(lastExecutedEpoch, dca.currentEpoch() - 1);
        assertEq(slippageBps, 300);
        assertTrue(active);

        // First execution should be ripe immediately.
        assertTrue(dca.isRipe(id));

        uint256[] memory ids = dca.getPositionsByOwner(ALICE);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        assertEq(dca.nextPositionId(), 2);
    }

    function test_CreatePosition_RevertsZeroTotal() public {
        _approveUsdc(ALICE, 1000e6);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.ZeroAmount.selector);
        dca.createPosition(0, 100e6, 1);
    }

    function test_CreatePosition_RevertsZeroPerSwap() public {
        _approveUsdc(ALICE, 1000e6);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.ZeroAmount.selector);
        dca.createPosition(1000e6, 0, 1);
    }

    function test_CreatePosition_RevertsAmountExceedsTotal() public {
        _approveUsdc(ALICE, 1000e6);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.AmountExceedsBalance.selector);
        dca.createPosition(1000e6, 2000e6, 1);
    }

    function test_CreatePosition_RevertsZeroInterval() public {
        _approveUsdc(ALICE, 1000e6);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.ZeroInterval.selector);
        dca.createPosition(1000e6, 100e6, 0);
    }

    function test_CreatePosition_RevertsWhenPaused() public {
        vm.prank(OWNER);
        dca.pause();

        _approveUsdc(ALICE, 1000e6);
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        dca.createPosition(1000e6, 100e6, 1);
    }

    // -------------------------------------------------------------------------
    // topUpPosition
    // -------------------------------------------------------------------------

    function test_TopUp_Happy() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        _approveUsdc(ALICE, 500e6);
        vm.prank(ALICE);
        dca.topUpPosition(id, 500e6);

        (, uint256 usdcBalance,,,,,,) = _readPosition(id);
        assertEq(usdcBalance, 1500e6);
    }

    function test_TopUp_RevertsNotOwner() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        _approveUsdc(BOB, 500e6);
        vm.prank(BOB);
        vm.expectRevert(CLAWDdca.NotPositionOwner.selector);
        dca.topUpPosition(id, 500e6);
    }

    function test_TopUp_RevertsInactive() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(ALICE);
        dca.closePosition(id);

        _approveUsdc(ALICE, 500e6);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.PositionInactive.selector);
        dca.topUpPosition(id, 500e6);
    }

    function test_TopUp_RevertsWhenPaused() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(OWNER);
        dca.pause();

        _approveUsdc(ALICE, 500e6);
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        dca.topUpPosition(id, 500e6);
    }

    function test_TopUp_RevertsZeroAmount() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.ZeroAmount.selector);
        dca.topUpPosition(id, 0);
    }

    // -------------------------------------------------------------------------
    // executeDCA
    // -------------------------------------------------------------------------

    function test_ExecuteDCA_Happy() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        uint256 swapAmount = 100e6;
        uint256 keeperFee = (swapAmount * KEEPER_FEE_BPS) / BPS_DENOM; // 0.20%
        uint256 protocolFee = (swapAmount * PROTOCOL_FEE_BPS) / BPS_DENOM; // 0.10%
        uint256 burnFee = (swapAmount * BURN_FEE_BPS) / BPS_DENOM; // 0.20%
        uint256 swapInput = swapAmount - keeperFee - protocolFee - burnFee;

        uint256 keeperUsdcBefore = IERC20(USDC_ADDR).balanceOf(KEEPER);
        uint256 contractUsdcBefore = IERC20(USDC_ADDR).balanceOf(address(dca));

        vm.prank(KEEPER);
        dca.executeDCA(id);

        // Keeper got the keeper fee in USDC.
        assertEq(IERC20(USDC_ADDR).balanceOf(KEEPER) - keeperUsdcBefore, keeperFee);

        // Position state.
        (, uint256 usdcBalance, uint256 clawdAccrued,,, uint256 lastEpoch,,) = _readPosition(id);
        assertEq(usdcBalance, 1000e6 - swapAmount);
        // CLAWD received = swapInput * RATE_NUM / RATE_DENOM
        uint256 expectedClawd = (swapInput * RATE_NUM) / RATE_DENOM;
        assertEq(clawdAccrued, expectedClawd);
        assertEq(lastEpoch, dca.currentEpoch());

        // Protocol and burn fees accrued.
        assertEq(dca.protocolFeeBalance(), protocolFee);
        assertEq(dca.burnFeeBalance(), burnFee);

        // Contract USDC: started with 1000e6, sent swapInput to router and keeperFee to keeper.
        // protocolFee and burnFee remain in contract (as tracked balances). Net held in contract:
        // 1000e6 - swapInput - keeperFee.
        assertEq(
            IERC20(USDC_ADDR).balanceOf(address(dca)),
            contractUsdcBefore - swapInput - keeperFee
        );
    }

    function test_ExecuteDCA_NotRipe() public {
        // Create a position that is NOT immediately ripe by warping forward then forward by less than interval.
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 2);

        // Position WAS immediately ripe. Execute once.
        vm.prank(KEEPER);
        dca.executeDCA(id);

        // Now last epoch == currentEpoch; interval is 2 so we need to wait 2 epochs.
        vm.prank(KEEPER);
        vm.expectRevert(CLAWDdca.NotRipe.selector);
        dca.executeDCA(id);

        // Warp forward 1 epoch — still not ripe.
        vm.warp(block.timestamp + 3 hours);
        vm.prank(KEEPER);
        vm.expectRevert(CLAWDdca.NotRipe.selector);
        dca.executeDCA(id);

        // Warp forward another epoch — now ripe.
        vm.warp(block.timestamp + 3 hours);
        vm.prank(KEEPER);
        dca.executeDCA(id);
    }

    function test_ExecuteDCA_RevertsInactive() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(ALICE);
        dca.closePosition(id);

        vm.prank(KEEPER);
        vm.expectRevert(CLAWDdca.PositionInactive.selector);
        dca.executeDCA(id);
    }

    function test_ExecuteDCA_RevertsWhenPaused() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(OWNER);
        dca.pause();

        vm.prank(KEEPER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        dca.executeDCA(id);
    }

    function test_ExecuteDCA_PartialExecutionDeactivates() public {
        // amountPerSwap > remaining balance after one swap → partial swap, deactivate.
        // total=150 USDC, perSwap=100 USDC, interval=1.
        // First exec: spends 100, leaves 50. Second exec spends 50 (capped), deactivates.
        uint256 id = _createPosition(ALICE, 150e6, 100e6, 1);

        vm.prank(KEEPER);
        dca.executeDCA(id);

        (, uint256 usdcBalance,,,,,, bool active1) = _readPosition(id);
        assertEq(usdcBalance, 50e6);
        assertTrue(active1);

        // Warp one epoch forward.
        vm.warp(block.timestamp + 3 hours);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        (, uint256 usdcBalance2,,,,,, bool active2) = _readPosition(id);
        assertEq(usdcBalance2, 0);
        assertFalse(active2);
    }

    function test_ExecuteDCA_SlippageReverts() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        // Make the router return less than the quoter's expected output, below the slippage floor.
        // expectedOut from quoter = swapInput * RATE_NUM / RATE_DENOM.
        // amountOutMinimum = expectedOut * (10000 - 300) / 10000 = expectedOut * 9700 / 10000
        // Force router to output less than that.
        uint256 swapAmount = 100e6;
        uint256 keeperFee = (swapAmount * KEEPER_FEE_BPS) / BPS_DENOM;
        uint256 protocolFee = (swapAmount * PROTOCOL_FEE_BPS) / BPS_DENOM;
        uint256 burnFee = (swapAmount * BURN_FEE_BPS) / BPS_DENOM;
        uint256 swapInput = swapAmount - keeperFee - protocolFee - burnFee;
        uint256 expectedOut = (swapInput * RATE_NUM) / RATE_DENOM;
        uint256 minOut = (expectedOut * 9700) / 10_000;
        // Router will return less than minOut.
        MockSwapRouter(ROUTER_ADDR).setForceOutput(minOut - 1);

        vm.prank(KEEPER);
        vm.expectRevert(bytes("Too little received"));
        dca.executeDCA(id);
    }

    function test_ExecuteDCA_FirstExecutionImmediatelyRipe() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 5);
        // intervalInEpochs is 5 yet we should be ripe immediately.
        assertTrue(dca.isRipe(id));
        vm.prank(KEEPER);
        dca.executeDCA(id);
    }

    function test_ExecuteDCA_ReentrancyBlocked() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        // Wire up the router to call back into dca.executeDCA during the swap.
        bytes memory reentryCalldata = abi.encodeWithSelector(CLAWDdca.executeDCA.selector, id);
        MockSwapRouter(ROUTER_ADDR).setReentrancy(address(dca), reentryCalldata);

        // The reentry attempt should fail silently inside the router (it swallows the call result),
        // but the outer call must still succeed because the inner call was reverted.
        // Actually, our mock SILENTLY swallows reentrancy results, so the outer call succeeds even though the
        // reentrant call would have reverted. Let's verify: position got executed exactly once (not twice).
        vm.prank(KEEPER);
        dca.executeDCA(id);

        (, uint256 usdcBalance,,,,,,) = _readPosition(id);
        // Only ONE swap happened — usdcBalance went from 1000e6 to 900e6.
        assertEq(usdcBalance, 900e6);
    }

    function test_ExecuteDCA_RevertsZeroBalance() public {
        // Create a position that has been emptied. Simplest path: closePosition then re-check.
        uint256 id = _createPosition(ALICE, 100e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);
        // After this single swap the position has zero balance and is deactivated.
        (, uint256 usdcBalance,,,,,, bool active) = _readPosition(id);
        assertEq(usdcBalance, 0);
        assertFalse(active);

        // Re-execute should revert PositionInactive.
        vm.prank(KEEPER);
        vm.expectRevert(CLAWDdca.PositionInactive.selector);
        dca.executeDCA(id);
    }

    // -------------------------------------------------------------------------
    // executeBatch
    // -------------------------------------------------------------------------

    function test_ExecuteBatch_Happy() public {
        uint256 id1 = _createPosition(ALICE, 1000e6, 100e6, 1);
        uint256 id2 = _createPosition(BOB, 2000e6, 200e6, 1);
        uint256 id3 = _createPosition(ALICE, 500e6, 50e6, 1);

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        vm.prank(KEEPER);
        dca.executeBatch(ids);

        (, uint256 b1,,,, uint256 le1,,) = _readPosition(id1);
        (, uint256 b2,,,, uint256 le2,,) = _readPosition(id2);
        (, uint256 b3,,,, uint256 le3,,) = _readPosition(id3);
        assertEq(b1, 900e6);
        assertEq(b2, 1800e6);
        assertEq(b3, 450e6);
        uint256 e = dca.currentEpoch();
        assertEq(le1, e);
        assertEq(le2, e);
        assertEq(le3, e);
    }

    function test_ExecuteBatch_SkipsNotRipe() public {
        uint256 id1 = _createPosition(ALICE, 1000e6, 100e6, 1);
        uint256 id2 = _createPosition(BOB, 2000e6, 200e6, 1);

        // Execute id1 individually first to bring its lastEpoch to current, making it not-ripe for the batch.
        vm.prank(KEEPER);
        dca.executeDCA(id1);

        (, uint256 b1Before,,,,,,) = _readPosition(id1);
        assertEq(b1Before, 900e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        // Batch should skip id1 (not ripe) and execute id2.
        vm.prank(KEEPER);
        dca.executeBatch(ids);

        (, uint256 b1After,,,,,,) = _readPosition(id1);
        (, uint256 b2,,,,,,) = _readPosition(id2);
        assertEq(b1After, 900e6); // unchanged
        assertEq(b2, 1800e6); // executed
    }

    function test_ExecuteBatch_AllInactiveNoOp() public {
        uint256 id1 = _createPosition(ALICE, 1000e6, 100e6, 1);
        uint256 id2 = _createPosition(BOB, 2000e6, 200e6, 1);

        vm.prank(ALICE);
        dca.closePosition(id1);
        vm.prank(BOB);
        dca.closePosition(id2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        vm.prank(KEEPER);
        dca.executeBatch(ids); // should not revert
    }

    function test_ExecuteBatch_RevertsWhenPaused() public {
        uint256 id1 = _createPosition(ALICE, 1000e6, 100e6, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;

        vm.prank(OWNER);
        dca.pause();

        vm.prank(KEEPER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        dca.executeBatch(ids);
    }

    // -------------------------------------------------------------------------
    // withdrawCLAWD
    // -------------------------------------------------------------------------

    function test_WithdrawCLAWD_Happy() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        vm.prank(KEEPER);
        dca.executeDCA(id);

        (,, uint256 clawdAccrued,,,,,) = _readPosition(id);
        assertGt(clawdAccrued, 0);

        uint256 aliceClawdBefore = IERC20(CLAWD_ADDR).balanceOf(ALICE);
        vm.prank(ALICE);
        dca.withdrawCLAWD(id);
        assertEq(IERC20(CLAWD_ADDR).balanceOf(ALICE) - aliceClawdBefore, clawdAccrued);

        (,, uint256 clawdAccruedAfter,,,,,) = _readPosition(id);
        assertEq(clawdAccruedAfter, 0);
    }

    function test_WithdrawCLAWD_AllowedWhenPaused() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        vm.prank(OWNER);
        dca.pause();

        // Withdraw should still work.
        vm.prank(ALICE);
        dca.withdrawCLAWD(id);
    }

    function test_WithdrawCLAWD_RevertsNotOwner() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        vm.prank(BOB);
        vm.expectRevert(CLAWDdca.NotPositionOwner.selector);
        dca.withdrawCLAWD(id);
    }

    function test_WithdrawCLAWD_RevertsZeroBalance() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        // No execution yet, so clawdAccrued = 0.
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.ZeroAmount.selector);
        dca.withdrawCLAWD(id);
    }

    // -------------------------------------------------------------------------
    // closePosition
    // -------------------------------------------------------------------------

    function test_ClosePosition_ReturnsBothTokens() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        (, uint256 usdcBalance, uint256 clawdAccrued,,,,,) = _readPosition(id);
        assertGt(usdcBalance, 0);
        assertGt(clawdAccrued, 0);

        uint256 aliceUsdcBefore = IERC20(USDC_ADDR).balanceOf(ALICE);
        uint256 aliceClawdBefore = IERC20(CLAWD_ADDR).balanceOf(ALICE);

        vm.prank(ALICE);
        dca.closePosition(id);

        assertEq(IERC20(USDC_ADDR).balanceOf(ALICE) - aliceUsdcBefore, usdcBalance);
        assertEq(IERC20(CLAWD_ADDR).balanceOf(ALICE) - aliceClawdBefore, clawdAccrued);

        (, uint256 usdcBalanceAfter, uint256 clawdAccruedAfter,,,,, bool active) = _readPosition(id);
        assertEq(usdcBalanceAfter, 0);
        assertEq(clawdAccruedAfter, 0);
        assertFalse(active);
    }

    function test_ClosePosition_AllowedWhenPaused() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(OWNER);
        dca.pause();
        vm.prank(ALICE);
        dca.closePosition(id);
    }

    function test_ClosePosition_RevertsNotOwner() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(BOB);
        vm.expectRevert(CLAWDdca.NotPositionOwner.selector);
        dca.closePosition(id);
    }

    // -------------------------------------------------------------------------
    // setSlippageTolerance
    // -------------------------------------------------------------------------

    function test_SetSlippage_Happy() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(ALICE);
        dca.setSlippageTolerance(id, 500); // 5%

        (,,,,,, uint256 slippage,) = _readPosition(id);
        assertEq(slippage, 500);
    }

    function test_SetSlippage_RevertsNotOwner() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(BOB);
        vm.expectRevert(CLAWDdca.NotPositionOwner.selector);
        dca.setSlippageTolerance(id, 500);
    }

    function test_SetSlippage_RevertsAboveMax() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.SlippageTooHigh.selector);
        dca.setSlippageTolerance(id, 1001); // > MAX_SLIPPAGE_BPS
    }

    // -------------------------------------------------------------------------
    // collectProtocolFees
    // -------------------------------------------------------------------------

    function test_CollectProtocolFees_OwnerOnly() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        uint256 expectedFee = (100e6 * PROTOCOL_FEE_BPS) / BPS_DENOM;
        assertEq(dca.protocolFeeBalance(), expectedFee);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        dca.collectProtocolFees();

        uint256 ownerUsdcBefore = IERC20(USDC_ADDR).balanceOf(OWNER);
        vm.prank(OWNER);
        dca.collectProtocolFees();
        assertEq(IERC20(USDC_ADDR).balanceOf(OWNER) - ownerUsdcBefore, expectedFee);
        assertEq(dca.protocolFeeBalance(), 0);
    }

    function test_CollectProtocolFees_RevertsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(CLAWDdca.ZeroAmount.selector);
        dca.collectProtocolFees();
    }

    // -------------------------------------------------------------------------
    // setSwapPath
    // -------------------------------------------------------------------------

    function test_SetSwapPath_Happy() public {
        // Single-hop USDC -> CLAWD at 0.3% (3000) — 43 bytes.
        bytes memory newPath = abi.encodePacked(USDC_ADDR, uint24(3000), CLAWD_ADDR);
        assertEq(newPath.length, 43);

        vm.prank(OWNER);
        dca.setSwapPath(newPath);
        assertEq(dca.swapPath(), newPath);
    }

    function test_SetSwapPath_RevertsTooShort() public {
        bytes memory bad = new bytes(42);
        vm.prank(OWNER);
        vm.expectRevert(CLAWDdca.InvalidPath.selector);
        dca.setSwapPath(bad);
    }

    function test_SetSwapPath_RevertsNonOwner() public {
        bytes memory newPath = abi.encodePacked(USDC_ADDR, uint24(3000), CLAWD_ADDR);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        dca.setSwapPath(newPath);
    }

    function test_SetSwapPath_RevertsBadStartToken() public {
        // 43 bytes: <random>(20) + fee(3) + CLAWD(20) — starts with non-USDC.
        bytes memory bad = abi.encodePacked(address(0xDEAD), uint24(3000), CLAWD_ADDR);
        assertEq(bad.length, 43);
        vm.prank(OWNER);
        vm.expectRevert(CLAWDdca.InvalidPath.selector);
        dca.setSwapPath(bad);
    }

    function test_SetSwapPath_RevertsBadEndToken() public {
        // 43 bytes: USDC(20) + fee(3) + <random>(20) — ends with non-CLAWD.
        bytes memory bad = abi.encodePacked(USDC_ADDR, uint24(3000), address(0xDEAD));
        assertEq(bad.length, 43);
        vm.prank(OWNER);
        vm.expectRevert(CLAWDdca.InvalidPath.selector);
        dca.setSwapPath(bad);
    }

    function test_SetSwapPath_RevertsBadLength44() public {
        // 44 bytes — does not match (length - 20) % 23 == 0.
        bytes memory bad = new bytes(44);
        // Patch front and back so it would otherwise look valid.
        for (uint256 i = 0; i < 20; i++) bad[i] = bytes20(uint160(USDC_ADDR))[i];
        for (uint256 i = 0; i < 20; i++) bad[i + 24] = bytes20(uint160(CLAWD_ADDR))[i];
        vm.prank(OWNER);
        vm.expectRevert(CLAWDdca.InvalidPath.selector);
        dca.setSwapPath(bad);
    }

    function test_SetSwapPath_AcceptsSingleHopUsdcToClawd() public {
        // 43 bytes — valid single hop USDC → CLAWD direct.
        bytes memory newPath = abi.encodePacked(USDC_ADDR, uint24(3000), CLAWD_ADDR);
        assertEq(newPath.length, 43);
        vm.prank(OWNER);
        dca.setSwapPath(newPath);
        assertEq(dca.swapPath(), newPath);
    }

    function test_SetSwapPath_AcceptsMultiHopUsdcWethClawd() public {
        // 66 bytes — valid two-hop USDC → WETH → CLAWD.
        bytes memory newPath =
            abi.encodePacked(USDC_ADDR, uint24(500), address(0x4200000000000000000000000000000000000006), uint24(10_000), CLAWD_ADDR);
        assertEq(newPath.length, 66);
        vm.prank(OWNER);
        dca.setSwapPath(newPath);
        assertEq(dca.swapPath(), newPath);
    }

    // -------------------------------------------------------------------------
    // renounceOwnership override
    // -------------------------------------------------------------------------

    function test_RenounceOwnership_RevertsForOwner() public {
        // Owner calls renounceOwnership — must hit the override and revert with the custom error,
        // NOT actually transfer ownership to the zero address.
        vm.prank(OWNER);
        vm.expectRevert(CLAWDdca.OwnershipCannotBeRenounced.selector);
        dca.renounceOwnership();

        // Owner is unchanged.
        assertEq(dca.owner(), OWNER);
    }

    function test_RenounceOwnership_RevertsForNonOwner() public {
        // Non-owner cannot even reach the override body — Ownable's onlyOwner check fires first.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        dca.renounceOwnership();

        assertEq(dca.owner(), OWNER);
    }

    // -------------------------------------------------------------------------
    // executeDCAWithMin (off-chain quote keeper path)
    // -------------------------------------------------------------------------

    function test_ExecuteDCAWithMin_Happy() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        uint256 swapAmount = 100e6;
        uint256 keeperFee = (swapAmount * KEEPER_FEE_BPS) / BPS_DENOM;
        uint256 protocolFee = (swapAmount * PROTOCOL_FEE_BPS) / BPS_DENOM;
        uint256 burnFee = (swapAmount * BURN_FEE_BPS) / BPS_DENOM;
        uint256 swapInput = swapAmount - keeperFee - protocolFee - burnFee;
        uint256 expectedOut = (swapInput * RATE_NUM) / RATE_DENOM;

        // Keeper supplies amountOutMinimum directly. Use 95% of expectedOut as a 5% slippage tolerance.
        uint256 keeperMinOut = (expectedOut * 9500) / 10_000;

        uint256 keeperUsdcBefore = IERC20(USDC_ADDR).balanceOf(KEEPER);

        vm.prank(KEEPER);
        dca.executeDCAWithMin(id, keeperMinOut);

        // Keeper got the keeper fee in USDC.
        assertEq(IERC20(USDC_ADDR).balanceOf(KEEPER) - keeperUsdcBefore, keeperFee);

        // Position state advanced.
        (, uint256 usdcBalance, uint256 clawdAccrued,,, uint256 lastEpoch,,) = _readPosition(id);
        assertEq(usdcBalance, 1000e6 - swapAmount);
        assertEq(clawdAccrued, expectedOut);
        assertEq(lastEpoch, dca.currentEpoch());
        assertEq(dca.protocolFeeBalance(), protocolFee);
    }

    function test_ExecuteDCAWithMin_RevertsBelowSuppliedMin() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        uint256 swapAmount = 100e6;
        uint256 keeperFee = (swapAmount * KEEPER_FEE_BPS) / BPS_DENOM;
        uint256 protocolFee = (swapAmount * PROTOCOL_FEE_BPS) / BPS_DENOM;
        uint256 burnFee = (swapAmount * BURN_FEE_BPS) / BPS_DENOM;
        uint256 swapInput = swapAmount - keeperFee - protocolFee - burnFee;
        uint256 expectedOut = (swapInput * RATE_NUM) / RATE_DENOM;

        // Force the router to deliver less than the keeper's supplied minimum.
        uint256 keeperMinOut = expectedOut; // demand exactly the full quote
        MockSwapRouter(ROUTER_ADDR).setForceOutput(keeperMinOut - 1);

        vm.prank(KEEPER);
        vm.expectRevert(bytes("Too little received"));
        dca.executeDCAWithMin(id, keeperMinOut);
    }

    function test_ExecuteDCAWithMin_RevertsWhenPaused() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(OWNER);
        dca.pause();

        vm.prank(KEEPER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        dca.executeDCAWithMin(id, 0);
    }

    function test_ExecuteDCAWithMin_NotRipe() public {
        // Create a position with a 2-epoch interval, execute once to consume immediate ripeness,
        // then attempt with executeDCAWithMin and expect NotRipe.
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 2);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        vm.prank(KEEPER);
        vm.expectRevert(CLAWDdca.NotRipe.selector);
        dca.executeDCAWithMin(id, 0);
    }

    function test_ExecuteDCAWithMin_ZeroMinAcceptsAnyOutput() public {
        // amountOutMinimum = 0 means router can return any amount including 1 wei. The keeper-supplied
        // path is the user's responsibility — this test confirms zero is accepted (sandwich risk explicit).
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        // Force router to return only 1 wei of CLAWD.
        MockSwapRouter(ROUTER_ADDR).setForceOutput(1);

        vm.prank(KEEPER);
        dca.executeDCAWithMin(id, 0);

        (,, uint256 clawdAccrued,,,,,) = _readPosition(id);
        assertEq(clawdAccrued, 1);
    }

    // -------------------------------------------------------------------------
    // closePosition double-close (Low-2)
    // -------------------------------------------------------------------------

    function test_ClosePosition_RevertsWhenAlreadyClosed() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(ALICE);
        dca.closePosition(id);

        // Re-closing must revert PositionInactive (no double PositionClosed event).
        vm.prank(ALICE);
        vm.expectRevert(CLAWDdca.PositionInactive.selector);
        dca.closePosition(id);
    }

    // -------------------------------------------------------------------------
    // pause / unpause
    // -------------------------------------------------------------------------

    function test_Pause_OwnerOnly() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        dca.pause();

        vm.prank(OWNER);
        dca.pause();
        assertTrue(dca.paused());

        vm.prank(OWNER);
        dca.unpause();
        assertFalse(dca.paused());
    }

    // -------------------------------------------------------------------------
    // Ownable2Step transfer flow
    // -------------------------------------------------------------------------

    function test_Ownable2Step_TransferFlow() public {
        // Step 1: current owner proposes a new owner.
        vm.prank(OWNER);
        dca.transferOwnership(ALICE);

        // Owner is still OWNER until ALICE accepts.
        assertEq(dca.owner(), OWNER);
        assertEq(dca.pendingOwner(), ALICE);

        // ALICE accepts.
        vm.prank(ALICE);
        dca.acceptOwnership();

        assertEq(dca.owner(), ALICE);
        assertEq(dca.pendingOwner(), address(0));
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function test_GetRipePositions() public {
        uint256 id1 = _createPosition(ALICE, 1000e6, 100e6, 1);
        uint256 id2 = _createPosition(BOB, 2000e6, 200e6, 1);

        // Execute id1 to make it not-ripe; id2 stays ripe.
        vm.prank(KEEPER);
        dca.executeDCA(id1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint256[] memory ripe = dca.getRipePositions(ids);
        assertEq(ripe.length, 1);
        assertEq(ripe[0], id2);
    }

    function test_IsRipe_HandlesAllStates() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        assertTrue(dca.isRipe(id));

        vm.prank(KEEPER);
        dca.executeDCA(id);
        assertFalse(dca.isRipe(id)); // just executed

        vm.warp(block.timestamp + 3 hours);
        assertTrue(dca.isRipe(id));

        vm.prank(ALICE);
        dca.closePosition(id);
        assertFalse(dca.isRipe(id)); // inactive
    }

    // -------------------------------------------------------------------------
    // executeBurn (v2)
    // -------------------------------------------------------------------------

    function test_ExecuteBurn_AccumulatesAcrossExecutions() public {
        // Two positions execute → burnFeeBalance accumulates for both.
        uint256 id1 = _createPosition(ALICE, 1000e6, 100e6, 1);
        uint256 id2 = _createPosition(BOB, 500e6, 50e6, 1);

        vm.prank(KEEPER);
        dca.executeDCA(id1);
        vm.prank(KEEPER);
        dca.executeDCA(id2);

        uint256 expected1 = (100e6 * BURN_FEE_BPS) / BPS_DENOM;
        uint256 expected2 = (50e6 * BURN_FEE_BPS) / BPS_DENOM;
        assertEq(dca.burnFeeBalance(), expected1 + expected2);
    }

    function test_ExecuteBurn_Happy() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        uint256 burnAccrued = dca.burnFeeBalance();
        assertGt(burnAccrued, 0);

        // The burn address had 0 CLAWD before.
        address dead = 0x000000000000000000000000000000000000dEaD;
        uint256 deadClawdBefore = IERC20(CLAWD_ADDR).balanceOf(dead);

        // Any address can call executeBurn.
        address anyone = address(0xBEEFCAFE);
        vm.prank(anyone);
        dca.executeBurn();

        // burnFeeBalance zeroed.
        assertEq(dca.burnFeeBalance(), 0);

        // CLAWD was sent to 0xdead.
        uint256 deadClawdAfter = IERC20(CLAWD_ADDR).balanceOf(dead);
        assertGt(deadClawdAfter - deadClawdBefore, 0);

        // The expected CLAWD ≈ burnAccrued * RATE_NUM / RATE_DENOM (within slippage tolerance).
        // With DEFAULT_SLIPPAGE_BPS = 300 the swap won't revert at mock rate 100e18/1e6.
        uint256 expectedClawd = (burnAccrued * RATE_NUM) / RATE_DENOM;
        // Allow for slippage floor — actual must be ≥ expectedClawd * 9700 / 10000.
        assertGe(deadClawdAfter - deadClawdBefore, (expectedClawd * 9700) / 10_000);
    }

    function test_ExecuteBurn_RevertsZeroBalance() public {
        vm.expectRevert(CLAWDdca.ZeroAmount.selector);
        dca.executeBurn();
    }

    function test_ExecuteBurn_RevertsWhenSlippageTooHigh() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);
        vm.prank(KEEPER);
        dca.executeDCA(id);

        uint256 burnAccrued = dca.burnFeeBalance();
        uint256 expectedOut = (burnAccrued * RATE_NUM) / RATE_DENOM;
        uint256 minOut = (expectedOut * 9700) / 10_000;
        // Force router to return less than slippage floor.
        MockSwapRouter(ROUTER_ADDR).setForceOutput(minOut - 1);

        vm.expectRevert(bytes("Too little received"));
        dca.executeBurn();
    }

    function test_ExecuteBurn_BurnFeeAccruedInDCAExecuted() public {
        uint256 id = _createPosition(ALICE, 1000e6, 100e6, 1);

        uint256 swapAmount = 100e6;
        uint256 expectedBurnFee = (swapAmount * BURN_FEE_BPS) / BPS_DENOM;

        vm.prank(KEEPER);
        dca.executeDCA(id);

        assertEq(dca.burnFeeBalance(), expectedBurnFee);
    }
}

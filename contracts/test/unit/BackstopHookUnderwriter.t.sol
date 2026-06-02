// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";
import {BackstopHook} from "../../src/BackstopHook.sol";

/// @notice tests for depositAsUnderwriter / withdrawAsUnderwriter / sweepToVaults.
contract BackstopHookUnderwriterTest is BackstopFixture {
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public override {
        super.setUp();

        // Fund + approve the two underwriters
        usdc.mint(carol, 1_000_000 ether);
        weth.mint(carol, 1_000_000 ether);
        usdc.mint(dave, 1_000_000 ether);
        weth.mint(dave, 1_000_000 ether);

        vm.prank(carol);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(carol);
        weth.approve(address(hook), type(uint256).max);
        vm.prank(dave);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(dave);
        weth.approve(address(hook), type(uint256).max);

        vm.label(carol, "carol");
        vm.label(dave, "dave");
    }

    function _swapExactIn(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SETTINGS,
            ZERO_BYTES
        );
    }

    // First deposit: 1:1 share minting

    function test_FirstDeposit_Mints1to1Shares_Then_Rebalances_8020() public {
        uint256 amount = 100 ether;
        uint256 expectedBuffer = (amount * hook.BUFFER_RATIO_BPS()) / 10_000;
        uint256 expectedVault = amount - expectedBuffer;

        vm.prank(carol);
        uint256 shares = hook.depositAsUnderwriter(address(usdc), amount);

        assertEq(shares, amount, "first depositor: shares == amount");
        assertEq(hook.usdcUnderwriterShares(carol), amount, "carol's USDC shares");
        assertEq(hook.totalUSDCUnderwriterShares(), amount, "total USDC shares");
        assertEq(hook.liquidBufferUSDC(), expectedBuffer, "buffer == 20% of deposit");
        // Mock vault mints shares 1:1 on first deposit so hook's USDC holdings equals 80% of deposit
        assertEq(usdcVault.totalAssets(), expectedVault, "vault holds 80% of deposit");
        assertEq(usdcVault.balanceOf(address(hook)), expectedVault, "hook owns all vault shares");
        assertEq(hook.totalWETHUnderwriterShares(), 0, "WETH side untouched");
    }

    // next deposit: proportional shares against current NAV

    // With no yield / claims, two deposits to the same pool
    // should yield share counts in the same ratio as the deposit amounts
    function test_SecondDeposit_GetsProportionalShares() public {
        vm.prank(carol);
        uint256 carolShares = hook.depositAsUnderwriter(address(usdc), 100 ether);

        vm.prank(dave);
        uint256 daveShares = hook.depositAsUnderwriter(address(usdc), 300 ether);

        assertEq(daveShares, 3 * carolShares, "Dave's shares should be 3x Carol's");
        assertEq(hook.totalUSDCUnderwriterShares(), carolShares + daveShares, "total shares accounting");
    }

    // Per-pool isolation (USDC vs WETH)

    // A deposit on the USDC side must NOT mint WETH shares, and vice versa
    function test_PerToken_SharesTrackedSeparately() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 100 ether);
        vm.prank(carol);
        hook.depositAsUnderwriter(address(weth), 5 ether);

        assertEq(hook.usdcUnderwriterShares(carol), 100 ether, "USDC shares");
        assertEq(hook.wethUnderwriterShares(carol), 5 ether, "WETH shares");
        // 20% of each deposit stays in the buffer, the rest is in the vault
        assertEq(hook.liquidBufferUSDC(), 20 ether, "USDC buffer = 20% of deposit");
        assertEq(hook.liquidBufferWETH(), 1 ether, "WETH buffer = 20% of deposit");
    }

    // sweepToVaults: 80/20 split + NAV growth

    // After swaps accrue some pending, sweepToVaults must move 20% to
    // liquidBuffer and 80% to the yield vault and zero the pending counter
    function test_SweepToVaults_Splits80_20_AndGrowsPoolValue() public {
        // Generate pending premium on at least one side
        _swapExactIn(true, 1e15);
        _swapExactIn(false, 1e15);

        uint256 usdcPendingBefore = hook.pendingUSDC();
        uint256 wethPendingBefore = hook.pendingWETH();
        require(usdcPendingBefore > 0 || wethPendingBefore > 0, "test setup: no pending");

        uint256 usdcBufferBefore = hook.liquidBufferUSDC();
        uint256 wethBufferBefore = hook.liquidBufferWETH();

        hook.sweepToVaults();

        // Pending counters cleared
        assertEq(hook.pendingUSDC(), 0, "USDC pending cleared");
        assertEq(hook.pendingWETH(), 0, "WETH pending cleared");

        // 20% to buffer
        uint256 expectedUsdcToBuffer = (usdcPendingBefore * hook.BUFFER_RATIO_BPS()) / 10_000;
        uint256 expectedWethToBuffer = (wethPendingBefore * hook.BUFFER_RATIO_BPS()) / 10_000;
        assertEq(hook.liquidBufferUSDC() - usdcBufferBefore, expectedUsdcToBuffer, "USDC buffer +20%");
        assertEq(hook.liquidBufferWETH() - wethBufferBefore, expectedWethToBuffer, "WETH buffer +20%");

        // 80% to vault, hook should now own vault shares whose underlying
        // value is approximately 80% of the swept amount
        uint256 expectedUsdcToVault = usdcPendingBefore - expectedUsdcToBuffer;
        uint256 expectedWethToVault = wethPendingBefore - expectedWethToBuffer;
        assertEq(usdcVault.balanceOf(address(hook)), expectedUsdcToVault, "hook USDC vault shares");
        assertEq(wethVault.balanceOf(address(hook)), expectedWethToVault, "hook WETH vault shares");
    }

    // An underwriter who deposited BEFORE the sweep should see their share
    // value rise after the sweep
    function test_SweepToVaults_GrowsSharePriceForPreSweepUnderwriter() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);

        _swapExactIn(true, 1e15);
        _swapExactIn(false, 1e15);

        uint256 valueBefore = hook.liquidBufferUSDC();

        hook.sweepToVaults();

        // NAV after sweep = buffer + vault assets
        uint256 navAfter = hook.liquidBufferUSDC() + usdcVault.totalAssets();
        // Carol owns all the USDC shares, so her slice == NAV
        assertGt(navAfter, valueBefore, "sweep should grow pool NAV");
    }

    // Sweeping with no pending on either side must succeed
    function test_SweepToVaults_ZeroPending_IsNoOp() public {
        uint256 usdcBufferBefore = hook.liquidBufferUSDC();
        uint256 wethBufferBefore = hook.liquidBufferWETH();

        hook.sweepToVaults();

        assertEq(hook.pendingUSDC(), 0);
        assertEq(hook.pendingWETH(), 0);
        assertEq(hook.liquidBufferUSDC(), usdcBufferBefore, "buffer unchanged");
        assertEq(hook.liquidBufferWETH(), wethBufferBefore, "buffer unchanged");
        assertEq(usdcVault.balanceOf(address(hook)), 0, "no vault deposit");
        assertEq(wethVault.balanceOf(address(hook)), 0, "no vault deposit");
    }

    // Withdraw: proportional payout

    // A solo underwriter who withdraws all of their shares must receive
    // exactly the NAV (buffer + vault-held)
    function test_Withdraw_ReturnsProportionalAmount() public {
        vm.prank(carol);
        uint256 shares = hook.depositAsUnderwriter(address(usdc), 100 ether);

        uint256 balanceBefore = usdc.balanceOf(carol);

        vm.prank(carol);
        uint256 amountOut = hook.withdrawAsUnderwriter(address(usdc), shares);

        assertEq(amountOut, 100 ether, "solo withdraw returns full deposit");
        assertEq(usdc.balanceOf(carol) - balanceBefore, 100 ether, "carol received tokens");
        assertEq(hook.usdcUnderwriterShares(carol), 0, "carol's shares burned");
        assertEq(hook.totalUSDCUnderwriterShares(), 0, "total shares zero");
        assertEq(hook.liquidBufferUSDC(), 0, "buffer drained");
    }

    // Ratio of payouts must match ratio of shares
    function test_Withdraw_TwoUsers_PayoutsScaleByShareRatio() public {
        vm.prank(carol);
        uint256 carolShares = hook.depositAsUnderwriter(address(usdc), 100 ether);
        vm.prank(dave);
        uint256 daveShares = hook.depositAsUnderwriter(address(usdc), 300 ether);

        vm.prank(carol);
        uint256 carolOut = hook.withdrawAsUnderwriter(address(usdc), carolShares);
        vm.prank(dave);
        uint256 daveOut = hook.withdrawAsUnderwriter(address(usdc), daveShares);

        assertEq(carolOut, 100 ether, "carol gets back her 100");
        assertEq(daveOut, 300 ether, "dave gets back his 300");
    }

    // Withdraw: buffer-first, vault fallback

    // If the buffer is smaller than the requested payout, the hook must
    // withdraw the rest from the vault
    function test_Withdraw_FallsBackToVault_WhenBufferInsufficient() public {
        vm.prank(carol);
        uint256 shares = hook.depositAsUnderwriter(address(usdc), 1_000 ether);

        for (uint256 i = 0; i < 8; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        hook.sweepToVaults();

        // some vault assets exist now.
        assertGt(usdcVault.balanceOf(address(hook)), 0, "vault should hold hook shares post-sweep");

        uint256 navBefore = hook.liquidBufferUSDC() + usdcVault.totalAssets();

        vm.prank(carol);
        uint256 amountOut = hook.withdrawAsUnderwriter(address(usdc), shares);

        // Carol owned 100% of USDC shares, she should receive all of NAV
        assertApproxEqAbs(amountOut, navBefore, 1, "amountOut ~= entire NAV");
        assertEq(usdcVault.balanceOf(address(hook)), 0, "vault drained of hook shares");
    }

    // Revert paths

    function test_RevertWhen_DepositAmountIsZero() public {
        vm.prank(carol);
        vm.expectRevert(BackstopHook.ZeroAmount.selector);
        hook.depositAsUnderwriter(address(usdc), 0);
    }

    function test_RevertWhen_WithdrawSharesIsZero() public {
        vm.prank(carol);
        vm.expectRevert(BackstopHook.ZeroShares.selector);
        hook.withdrawAsUnderwriter(address(usdc), 0);
    }

    function test_RevertWhen_WithdrawExceedsBalance() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 100 ether);

        vm.prank(carol);
        vm.expectRevert(BackstopHook.InsufficientShares.selector);
        hook.withdrawAsUnderwriter(address(usdc), 101 ether);
    }

    function test_RevertWhen_DepositTokenIsUnsupported() public {
        address bogus = makeAddr("bogus");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(BackstopHook.UnsupportedToken.selector, bogus));
        hook.depositAsUnderwriter(bogus, 100 ether);
    }

    function test_RevertWhen_WithdrawTokenIsUnsupported() public {
        address bogus = makeAddr("bogus");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(BackstopHook.UnsupportedToken.selector, bogus));
        hook.withdrawAsUnderwriter(bogus, 100 ether);
    }
}

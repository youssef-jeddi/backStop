// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";

/// @notice view-function tests
contract BackstopHookViewsTest is BackstopFixture {
    address internal carol = makeAddr("carol");

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public override {
        super.setUp();
        usdc.mint(carol, 1_000_000 ether);
        weth.mint(carol, 1_000_000 ether);
        vm.prank(carol);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(carol);
        weth.approve(address(hook), type(uint256).max);
        vm.label(carol, "carol");
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

    function test_GetCurrentVolatility_MatchesCalculateVolatility() public {
        _swapExactIn(true, 1e15);
        _swapExactIn(false, 1e15);
        _swapExactIn(true, 1e15);
        assertEq(hook.getCurrentVolatility(), hook.calculateVolatility(), "alias drift");
    }

    function test_GetCurrentPremiumRate_MatchesGetPremiumRate() public {
        _swapExactIn(true, 1e15);
        _swapExactIn(false, 1e15);
        assertEq(hook.getCurrentPremiumRate(), hook.getPremiumRate(), "alias drift");
    }

    // getReserveComposition returns the right fields
    function test_GetReserveComposition_AllZeros_OnFreshPool() public view {
        (uint256 b, uint256 v, uint256 s) = hook.getReserveComposition(address(usdc));
        assertEq(b, 0);
        assertEq(v, 0);
        assertEq(s, 0);
    }

    function test_GetReserveComposition_ReflectsDepositAndSweep() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 100 ether);

        for (uint256 i = 0; i < 8; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        hook.sweepToVaults();

        (uint256 b, uint256 v, uint256 s) = hook.getReserveComposition(address(usdc));

        assertEq(b, hook.liquidBufferUSDC(), "buffer field");
        assertEq(s, hook.totalUSDCUnderwriterShares(), "shares field");
        uint256 expectedVaultAssets =
            (usdcVault.totalAssets() * usdcVault.balanceOf(address(hook))) / usdcVault.totalShares();
        assertEq(v, expectedVaultAssets, "vault assets field");
    }

    function test_GetUnderwriterShares_MatchesMapping() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 50 ether);

        assertEq(hook.getUnderwriterShares(carol, address(usdc)), hook.usdcUnderwriterShares(carol));
        assertEq(hook.getUnderwriterShares(carol, address(weth)), 0);
    }

    // APY breakdown on a fresh pool
    function test_GetAPYBreakdown_FreshPool_AllZeros() public view {
        (uint256 p, uint256 v, uint256 c, int256 n) = hook.getUnderwriterAPYBreakdown(address(usdc));
        assertEq(p, 0);
        assertEq(v, 0);
        assertEq(c, 0);
        assertEq(n, int256(0));
    }

    // premiumAPY follows the formula
    function test_PremiumAPY_MatchesFormula() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);

        for (uint256 i = 0; i < 12; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        hook.sweepToVaults();

        vm.warp(block.timestamp + 30 days);

        assertGt(hook.totalPremiumsAccumulatedUSDC(), 0, "test setup: USDC premium should have accrued");

        (uint256 buffer, uint256 vaultAssets,) = hook.getReserveComposition(address(usdc));
        uint256 nav = buffer + vaultAssets;
        uint256 poolAge = block.timestamp - hook.poolStartTimestamp();
        uint256 expectedAPY = (hook.totalPremiumsAccumulatedUSDC() * hook.SECONDS_PER_YEAR() * 10_000) / (nav * poolAge);

        (uint256 actualAPY,,,) = hook.getUnderwriterAPYBreakdown(address(usdc));
        assertEq(actualAPY, expectedAPY, "premiumAPY formula mismatch");
    }

    // vaultAPY appears after simulated vault yield
    function test_VaultAPY_MatchesFormula_AfterSimulateYield() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);

        for (uint256 i = 0; i < 8; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        // moves 80% of pending into the USDC vault
        hook.sweepToVaults();

        // simulate 10% yield
        usdcVault.simulateYield(1_000);

        vm.warp(block.timestamp + 30 days);

        // the vault is now worth more than what the hook put into it
        assertGt(
            usdcVault.totalAssets(),
            hook.totalVaultUSDCDeposited(),
            "test setup: vault should hold more than deposited principal after simulateYield"
        );

        (uint256 buffer, uint256 vaultAssets,) = hook.getReserveComposition(address(usdc));
        uint256 nav = buffer + vaultAssets;
        uint256 poolAge = block.timestamp - hook.poolStartTimestamp();
        uint256 grossOut = vaultAssets + hook.totalVaultUSDCWithdrawn();
        uint256 vaultYield = grossOut > hook.totalVaultUSDCDeposited() ? grossOut - hook.totalVaultUSDCDeposited() : 0;
        uint256 expectedVaultAPY = (vaultYield * hook.SECONDS_PER_YEAR() * 10_000) / (nav * poolAge);

        (, uint256 actualVaultAPY,,) = hook.getUnderwriterAPYBreakdown(address(usdc));
        assertEq(actualVaultAPY, expectedVaultAPY, "vaultAPY formula mismatch");
    }

    // Trigger an IL payout and verify that netAPY reflects the loss.
    function test_ClaimDragBps_AppearsAfterILPayout() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 100 ether);
        vm.prank(carol);
        hook.depositAsUnderwriter(address(weth), 100 ether);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -3_000, tickUpper: 3_000, liquidityDelta: 1e18, salt: bytes32(uint256(0xDEAD))
            }),
            ZERO_BYTES
        );
        _swapExactIn(true, 5e17);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -3_000, tickUpper: 3_000, liquidityDelta: -1e18, salt: bytes32(uint256(0xDEAD))
            }),
            ZERO_BYTES
        );

        require(hook.totalClaimsPaidUSDC() + hook.totalClaimsPaidWETH() > 0, "test setup: an IL claim must have fired");

        vm.warp(block.timestamp + 30 days);

        // Pick whichever side saw a claim
        address claimToken = hook.totalClaimsPaidUSDC() > 0 ? address(usdc) : address(weth);
        (,, uint256 drag,) = hook.getUnderwriterAPYBreakdown(claimToken);
        assertGt(drag, 0, "non-zero claims should produce non-zero claim drag");
    }

    // netAPY must equal (premiumAPY + vaultAPY) − claimDragBps
    function test_NetAPY_EqualsSumMinusDrag() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);

        for (uint256 i = 0; i < 8; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        hook.sweepToVaults();
        usdcVault.simulateYield(500);
        vm.warp(block.timestamp + 60 days);

        (uint256 p, uint256 v, uint256 d, int256 n) = hook.getUnderwriterAPYBreakdown(address(usdc));
        int256 expectedNet = int256(p) + int256(v) - int256(d);
        assertEq(n, expectedNet, "netAPY must equal p + v - d");
    }

    // Unsupported token reverts on every view
    function test_GetReserveComposition_RevertsOnUnknownToken() public {
        vm.expectRevert();
        hook.getReserveComposition(address(0xBEEF));
    }

    function test_GetUnderwriterShares_RevertsOnUnknownToken() public {
        vm.expectRevert();
        hook.getUnderwriterShares(carol, address(0xBEEF));
    }

    function test_GetAPYBreakdown_RevertsOnUnknownToken() public {
        vm.expectRevert();
        hook.getUnderwriterAPYBreakdown(address(0xBEEF));
    }
}

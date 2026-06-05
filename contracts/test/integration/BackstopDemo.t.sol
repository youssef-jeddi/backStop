// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";

/// @notice end-to-end demo scenario
contract BackstopDemoIntegrationTest is BackstopFixture {
    address internal carol = makeAddr("carol");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // LP position parameters
    int24 internal constant LP_TICK_LOWER = -3_000;
    int24 internal constant LP_TICK_UPPER = 3_000;
    bytes32 internal constant LP_SALT = bytes32(uint256(0xA11CE));
    int256 internal constant LP_LIQUIDITY = 1e18;

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public override {
        super.setUp();
        _fund(carol);
        _fund(alice);
        _fund(bob);

        vm.label(carol, "carol-underwriter");
        vm.label(alice, "alice-LP");
        vm.label(bob, "bob-trader");
    }

    function _fund(address user) internal {
        usdc.mint(user, 10_000_000 ether);
        weth.mint(user, 10_000_000 ether);
        vm.startPrank(user);
        usdc.approve(address(hook), type(uint256).max);
        weth.approve(address(hook), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address trader, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(trader);
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

    function _addLP(address lp) internal {
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: LP_TICK_LOWER, tickUpper: LP_TICK_UPPER, liquidityDelta: LP_LIQUIDITY, salt: LP_SALT
            }),
            ZERO_BYTES
        );
    }

    function _removeLP(address lp) internal {
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: LP_TICK_LOWER, tickUpper: LP_TICK_UPPER, liquidityDelta: -LP_LIQUIDITY, salt: LP_SALT
            }),
            ZERO_BYTES
        );
    }

    function test_FullLifecycle_DemoScenario() public {
        console2.log("===========================================================");
        console2.log("  BackStop end-to-end demo");
        console2.log("===========================================================");

        _phase1_initialState();
        _phase2_underwriterDeposits();
        _phase3_lpAddsLiquidity();
        _phase4_calmTradingAccruesPremium();
        _phase5_sweep();
        _phase6_vaultEarnsYield();
        _phase7_volatileMove();
        _phase8_lpRemovesAndIsPaidOutForIL();
        _phase9_underwriterShareValueDropped();
        _phase10_apyBreakdown();
        _phase11_underwriterWithdraws();

        console2.log("===========================================================");
        console2.log("  demo complete");
        console2.log("===========================================================");
    }

    // ── phase helpers ───────────────────────────────────────────────────────

    function _phase1_initialState() internal view {
        console2.log("");
        console2.log("--- Phase 1: fresh deployment ---");
        console2.log("PoolManager:", address(manager));
        console2.log("BackstopHook:", address(hook));
        console2.log("USDC:", address(usdc));
        console2.log("WETH:", address(weth));
        console2.log("USDC vault:", address(usdcVault));
        console2.log("WETH vault:", address(wethVault));
        console2.log("pool fee model: DYNAMIC (target 0.30%, hook splits LP+premium per swap)");
    }

    function _phase2_underwriterDeposits() internal {
        console2.log("");
        console2.log("--- Phase 2: carol provides protection capital ---");

        vm.prank(carol);
        uint256 usdcShares = hook.depositAsUnderwriter(address(usdc), 1_000 ether);
        vm.prank(carol);
        uint256 wethShares = hook.depositAsUnderwriter(address(weth), 1_000 ether);

        console2.log("carol deposits 1000 USDC -> shares:", usdcShares);
        console2.log("carol deposits 1000 WETH -> shares:", wethShares);

        assertGt(usdcShares, 0, "carol must hold USDC shares");
        assertGt(wethShares, 0, "carol must hold WETH shares");
    }

    function _phase3_lpAddsLiquidity() internal {
        console2.log("");
        console2.log("--- Phase 3: alice provides pool liquidity ---");

        _addLP(alice);

        bytes32 key = keccak256(abi.encode(address(modifyLiquidityRouter), LP_TICK_LOWER, LP_TICK_UPPER, LP_SALT));
        (uint160 entrySqrt, uint128 entryLiq) = hook.lpPositions(key);

        console2.log("alice adds 1e18 liquidity at ticks [-3000, 3000]");
        console2.log("entry sqrtPriceX96:", uint256(entrySqrt));
        console2.log("entry liquidity:", uint256(entryLiq));

        assertEq(entrySqrt, SQRT_PRICE_1_1, "entry sqrtPrice recorded at pool 1:1");
        assertEq(uint256(entryLiq), uint256(uint256(int256(LP_LIQUIDITY))), "entry liquidity recorded");
    }

    function _phase4_calmTradingAccruesPremium() internal {
        console2.log("");
        console2.log("--- Phase 4: bob trades quietly, premium accrues ---");

        uint256 startRate = hook.getCurrentPremiumRate();
        console2.log("starting premium rate (bps):", startRate);

        for (uint256 i = 0; i < 16; ++i) {
            _swap(bob, i % 2 == 0, 1e15);
        }

        console2.log("after 16 alternating small swaps:");
        console2.log("  vol (cumulative bps):", hook.getCurrentVolatility());
        console2.log("  premium rate (bps):", hook.getCurrentPremiumRate());
        console2.log("  pending USDC:", hook.pendingUSDC());
        console2.log("  pending WETH:", hook.pendingWETH());

        assertGt(hook.pendingUSDC() + hook.pendingWETH(), 0, "premium should have accrued");
    }

    function _phase5_sweep() internal {
        console2.log("");
        console2.log("--- Phase 5: keeper sweeps premium into reserves ---");

        uint256 pUsdcBefore = hook.pendingUSDC();
        uint256 pWethBefore = hook.pendingWETH();

        hook.sweepToVaults();

        console2.log("swept 20% to buffer, 80% to yield vault on each side");
        console2.log("USDC buffer:", hook.liquidBufferUSDC());
        console2.log("WETH buffer:", hook.liquidBufferWETH());
        console2.log("USDC vault assets (hook-owned):", usdcVault.balanceOf(address(hook)));
        console2.log("WETH vault assets (hook-owned):", wethVault.balanceOf(address(hook)));

        assertEq(hook.pendingUSDC(), 0, "USDC pending must clear");
        assertEq(hook.pendingWETH(), 0, "WETH pending must clear");
        if (pUsdcBefore > 0) assertGt(usdcVault.balanceOf(address(hook)), 0, "USDC vault funded");
        if (pWethBefore > 0) assertGt(wethVault.balanceOf(address(hook)), 0, "WETH vault funded");
    }

    function _phase6_vaultEarnsYield() internal {
        console2.log("");
        console2.log("--- Phase 6: vault strategy earns yield (simulated) ---");

        uint256 navUsdcBefore;
        uint256 navWethBefore;
        {
            (uint256 b, uint256 v,) = hook.getReserveComposition(address(usdc));
            navUsdcBefore = b + v;
            (b, v,) = hook.getReserveComposition(address(weth));
            navWethBefore = b + v;
        }

        usdcVault.simulateYield(1_000); // +10%
        wethVault.simulateYield(1_000); // +10%

        uint256 navUsdcAfter;
        uint256 navWethAfter;
        {
            (uint256 b, uint256 v,) = hook.getReserveComposition(address(usdc));
            navUsdcAfter = b + v;
            (b, v,) = hook.getReserveComposition(address(weth));
            navWethAfter = b + v;
        }

        console2.log("USDC NAV before vault yield:", navUsdcBefore);
        console2.log("USDC NAV after vault yield:", navUsdcAfter);
        console2.log("WETH NAV before vault yield:", navWethBefore);
        console2.log("WETH NAV after vault yield:", navWethAfter);

        assertGe(navUsdcAfter, navUsdcBefore, "USDC NAV must grow (or hold) on vault yield");
        assertGe(navWethAfter, navWethBefore, "WETH NAV must grow (or hold) on vault yield");
    }

    function _phase7_volatileMove() internal {
        console2.log("");
        console2.log("--- Phase 7: crash event! one big swap pushes price ---");

        // Big swap to push sqrt-price beyond IL threshold
        _swap(bob, true, 5e17);

        console2.log("after large zeroForOne swap:");
        console2.log("  vol (cumulative bps):", hook.getCurrentVolatility());
        console2.log("  premium rate (bps):", hook.getCurrentPremiumRate());
    }

    function _phase8_lpRemovesAndIsPaidOutForIL() internal {
        console2.log("");
        console2.log("--- Phase 8: alice exits the pool, IL claim fires ---");

        uint256 claimsUsdcBefore = hook.totalClaimsPaidUSDC();
        uint256 claimsWethBefore = hook.totalClaimsPaidWETH();

        _removeLP(alice);

        uint256 paidUSDC = hook.totalClaimsPaidUSDC() - claimsUsdcBefore;
        uint256 paidWETH = hook.totalClaimsPaidWETH() - claimsWethBefore;

        console2.log("IL claim paid:");
        console2.log("  USDC:", paidUSDC);
        console2.log("  WETH:", paidWETH);

        assertGt(paidUSDC + paidWETH, 0, "IL payout must have fired");
    }

    function _phase9_underwriterShareValueDropped() internal view {
        console2.log("");
        console2.log("--- Phase 9: carol's share value reflects the loss ---");

        // Carol owns 100% of both pools, so her per-share NAV == NAV / totalShares
        (uint256 bufUsdc, uint256 vaUsdc, uint256 sharesUsdc) = hook.getReserveComposition(address(usdc));
        (uint256 bufWeth, uint256 vaWeth, uint256 sharesWeth) = hook.getReserveComposition(address(weth));

        uint256 navUsdc = bufUsdc + vaUsdc;
        uint256 navWeth = bufWeth + vaWeth;

        uint256 carolUsdcShare = (hook.usdcUnderwriterShares(carol) * navUsdc) / sharesUsdc;
        uint256 carolWethShare = (hook.wethUnderwriterShares(carol) * navWeth) / sharesWeth;

        // what carol would have been worth if no IL claim had ever fired
        // NAV would be larger by exactly the lifetime claims paid
        uint256 carolUsdcNoClaim =
            (hook.usdcUnderwriterShares(carol) * (navUsdc + hook.totalClaimsPaidUSDC())) / sharesUsdc;
        uint256 carolWethNoClaim =
            (hook.wethUnderwriterShares(carol) * (navWeth + hook.totalClaimsPaidWETH())) / sharesWeth;

        console2.log("carol's USDC redemption value (actual):", carolUsdcShare);
        console2.log("  ...if no IL claim had fired:", carolUsdcNoClaim);
        console2.log("carol's WETH redemption value (actual):", carolWethShare);
        console2.log("  ...if no IL claim had fired:", carolWethNoClaim);

        bool oneAffected = carolUsdcShare < carolUsdcNoClaim || carolWethShare < carolWethNoClaim;
        assertTrue(oneAffected, "at least one pool's share value should reflect the IL claim");
    }

    function _phase11_underwriterWithdraws() internal {
        console2.log("");
        console2.log("--- Phase 11: carol withdraws ---");

        uint256 sharesUsdc = hook.usdcUnderwriterShares(carol);
        uint256 sharesWeth = hook.wethUnderwriterShares(carol);

        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 wethBefore = weth.balanceOf(carol);

        vm.prank(carol);
        uint256 gotUsdc = hook.withdrawAsUnderwriter(address(usdc), sharesUsdc);
        vm.prank(carol);
        uint256 gotWeth = hook.withdrawAsUnderwriter(address(weth), sharesWeth);

        console2.log("carol withdrew USDC:", gotUsdc);
        console2.log("carol withdrew WETH:", gotWeth);

        assertEq(usdc.balanceOf(carol) - usdcBefore, gotUsdc);
        assertEq(weth.balanceOf(carol) - wethBefore, gotWeth);
        // Demo asserts the IL CLAIM was reflected (carol got less than she
        // would have without claims), not that she's net negative — vault
        // yield in phase 6 can leave her net positive vs her deposit, which
        // is the correct outcome of the system working.
        uint256 totalClaims = hook.totalClaimsPaidUSDC() + hook.totalClaimsPaidWETH();
        assertGt(totalClaims, 0, "an IL claim should have fired during the lifecycle");
    }

    function _phase10_apyBreakdown() internal {
        console2.log("");
        console2.log("--- Phase 10: APY breakdown after one month ---");

        // Advance time
        vm.warp(block.timestamp + 30 days);

        (uint256 p, uint256 v, uint256 c, int256 n) = hook.getUnderwriterAPYBreakdown(address(usdc));
        console2.log("USDC pool - premium APY (bps):", p);
        console2.log("USDC pool - vault APY (bps):", v);
        console2.log("USDC pool - claim drag (bps):", c);
        console2.log("USDC pool - NET APY (bps signed):", n);

        (p, v, c, n) = hook.getUnderwriterAPYBreakdown(address(weth));
        console2.log("WETH pool - premium APY (bps):", p);
        console2.log("WETH pool - vault APY (bps):", v);
        console2.log("WETH pool - claim drag (bps):", c);
        console2.log("WETH pool - NET APY (bps signed):", n);
    }
}

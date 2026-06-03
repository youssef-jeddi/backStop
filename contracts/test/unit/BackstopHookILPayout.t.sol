// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";

/// @notice _afterRemoveLiquidity IL payout tests
contract BackstopHookILPayoutTest is BackstopFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal carol = makeAddr("carol");

    // Wide tick range so swaps have room to move price
    int24 internal constant LP_TICK_LOWER = -3_000;
    int24 internal constant LP_TICK_UPPER = 3_000;
    bytes32 internal constant LP_SALT = bytes32(uint256(0xBEEF));

    // Liquidity amount for the test LP position
    int256 internal constant LP_LIQUIDITY = 1e18;

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public override {
        super.setUp();

        // Fund + approve carol on the underwriter side
        usdc.mint(carol, 1_000_000 ether);
        weth.mint(carol, 1_000_000 ether);
        vm.prank(carol);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(carol);
        weth.approve(address(hook), type(uint256).max);

        vm.label(carol, "carol");
    }

    // helpers

    function _addWideLP() internal returns (BalanceDelta) {
        return modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: LP_TICK_LOWER, tickUpper: LP_TICK_UPPER, liquidityDelta: LP_LIQUIDITY, salt: LP_SALT
            }),
            ZERO_BYTES
        );
    }

    function _removeWideLP() internal returns (BalanceDelta) {
        return modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: LP_TICK_LOWER, tickUpper: LP_TICK_UPPER, liquidityDelta: -LP_LIQUIDITY, salt: LP_SALT
            }),
            ZERO_BYTES
        );
    }

    function _swapExactIn(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
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

    // No payout when IL is below the threshold
    function test_NoPayout_WhenILBelowThreshold() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);
        vm.prank(carol);
        hook.depositAsUnderwriter(address(weth), 1_000 ether);

        _addWideLP();

        // Tiny swap so price barely moves and IL under threshold
        _swapExactIn(true, 1e15);

        uint256 navUsdcBefore = hook.liquidBufferUSDC();
        uint256 navWethBefore = hook.liquidBufferWETH();

        _removeWideLP();

        assertEq(hook.totalClaimsPaidUSDC(), 0, "no USDC claim should be paid");
        assertEq(hook.totalClaimsPaidWETH(), 0, "no WETH claim should be paid");
        assertGe(hook.liquidBufferUSDC(), navUsdcBefore, "USDC buffer must not have shrunk from a claim");
        assertGe(hook.liquidBufferWETH(), navWethBefore, "WETH buffer must not have shrunk from a claim");
    }

    // Payout when IL crosses the threshold — price up
    function test_PayoutFires_WhenILExceedsThreshold_PriceUp() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);
        vm.prank(carol);
        hook.depositAsUnderwriter(address(weth), 1_000 ether);

        _addWideLP();

        // Push price up enough to trigger IL > threshold
        _swapExactIn(true, 5e17);

        uint256 ilBps;
        {
            // Compute expected IL to be sure our swap crossed the threshold
            (uint160 currentSqrt,,,) = manager.getSlot0(poolKey.toId());
            ilBps = _ilOf(SQRT_PRICE_1_1, currentSqrt);
            assertGt(ilBps, hook.IL_THRESHOLD_BPS(), "test setup: must move price past IL threshold");
        }

        _removeWideLP();

        assertGt(
            hook.totalClaimsPaidUSDC() + hook.totalClaimsPaidWETH(), 0, "at least one side must have been paid out"
        );
    }

    // Buffer is used before the vault is touched
    function test_BufferDrainedFirst_VaultUntouched_WhenBufferCovers() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 1_000 ether);
        vm.prank(carol);
        hook.depositAsUnderwriter(address(weth), 1_000 ether);

        // Generate a small amount of pending so the vault has something
        for (uint256 i = 0; i < 4; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        hook.sweepToVaults();

        uint256 usdcVaultBalanceBefore = usdcVault.balanceOf(address(hook));
        uint256 wethVaultBalanceBefore = wethVault.balanceOf(address(hook));
        require(usdcVaultBalanceBefore > 0 || wethVaultBalanceBefore > 0, "test setup: vaults should be seeded");

        _addWideLP();
        _swapExactIn(true, 5e17);
        _removeWideLP();

        // Claim should be paid entirely from buffer
        // vault holding unchanged
        assertEq(usdcVault.balanceOf(address(hook)), usdcVaultBalanceBefore, "USDC vault must be untouched");
        assertEq(wethVault.balanceOf(address(hook)), wethVaultBalanceBefore, "WETH vault must be untouched");
    }

    // Vault fallback when buffer is insufficient
    function test_VaultFallback_WhenBufferInsufficient() public {
        vm.prank(carol);
        hook.depositAsUnderwriter(address(usdc), 0.1 ether);
        vm.prank(carol);
        hook.depositAsUnderwriter(address(weth), 0.1 ether);

        // Put premium into the vault with many swaps then sweep
        for (uint256 i = 0; i < 16; ++i) {
            _swapExactIn(i % 2 == 0, 1e15);
        }
        hook.sweepToVaults();

        uint256 usdcVaultBalanceBefore = usdcVault.balanceOf(address(hook));
        uint256 wethVaultBalanceBefore = wethVault.balanceOf(address(hook));

        _addWideLP();
        _swapExactIn(true, 5e17);
        _removeWideLP();

        // At least one vault must have been touched
        bool usdcVaultDecreased = usdcVault.balanceOf(address(hook)) < usdcVaultBalanceBefore;
        bool wethVaultDecreased = wethVault.balanceOf(address(hook)) < wethVaultBalanceBefore;
        assertTrue(usdcVaultDecreased || wethVaultDecreased, "vault fallback should have fired on at least one side");
    }

    // Underwriter share value drops after a payout
    function test_UnderwriterShareValue_DropsAfterClaim() public {
        uint256 deposit = 100 ether;
        vm.prank(carol);
        uint256 sharesUsdc = hook.depositAsUnderwriter(address(usdc), deposit);
        vm.prank(carol);
        uint256 sharesWeth = hook.depositAsUnderwriter(address(weth), deposit);

        _addWideLP();
        _swapExactIn(true, 5e17);
        _removeWideLP();

        uint256 usdcBalBefore = usdc.balanceOf(carol);
        uint256 wethBalBefore = weth.balanceOf(carol);

        vm.prank(carol);
        uint256 outUsdc = hook.withdrawAsUnderwriter(address(usdc), sharesUsdc);
        vm.prank(carol);
        uint256 outWeth = hook.withdrawAsUnderwriter(address(weth), sharesWeth);

        assertEq(usdc.balanceOf(carol) - usdcBalBefore, outUsdc);
        assertEq(weth.balanceOf(carol) - wethBalBefore, outWeth);

        // The two payouts together must be less than the two deposits
        assertLt(outUsdc + outWeth, deposit * 2, "carol's combined withdrawal must reflect the IL loss");
    }

    // helper

    function _ilOf(uint160 entry, uint160 exit_) internal pure returns (uint256) {
        if (entry == 0 || exit_ == 0 || entry == exit_) return 0;
        uint256 a = uint256(entry);
        uint256 b = uint256(exit_);
        uint256 m = a > b ? a : b;
        uint256 SCALE = 1 << 96;
        uint256 an = (a * SCALE) / m;
        uint256 bn = (b * SCALE) / m;
        uint256 d = an > bn ? an - bn : bn - an;
        return (10_000 * d * d) / (an * an + bn * bn);
    }
}

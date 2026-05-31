// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";

/// @notice dynamic LP fee + afterSwap return-delta accrual tests
contract BackstopHookSwapAccrualTest is BackstopFixture {
    uint256 internal constant SWAP_AMOUNT = 1e15;

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

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

    function _unspecifiedTokenForZeroForOne() internal view returns (address) {
        return usdcIsToken0 ? address(weth) : address(usdc);
    }

    function _unspecifiedTokenForOneForZero() internal view returns (address) {
        return usdcIsToken0 ? address(usdc) : address(weth);
    }

    // After a zeroForOne exactIn swap, the hook should hold real tokens of currency1
    function test_FirstSwap_ClaimsPremiumOnUnspecifiedCurrency() public {
        _swapExactIn(true, SWAP_AMOUNT);

        address unspecifiedToken = _unspecifiedTokenForZeroForOne();

        if (unspecifiedToken == address(usdc)) {
            assertGt(hook.pendingUSDC(), 0, "USDC pending must grow when USDC is unspecified");
            assertEq(hook.pendingWETH(), 0, "WETH side must stay untouched");
            assertEq(usdc.balanceOf(address(hook)), hook.pendingUSDC(), "real USDC == pendingUSDC");
            assertEq(weth.balanceOf(address(hook)), 0, "no WETH yet");
        } else {
            assertGt(hook.pendingWETH(), 0, "WETH pending must grow when WETH is unspecified");
            assertEq(hook.pendingUSDC(), 0, "USDC side must stay untouched");
            assertEq(weth.balanceOf(address(hook)), hook.pendingWETH(), "real WETH == pendingWETH");
            assertEq(usdc.balanceOf(address(hook)), 0, "no USDC yet");
        }
    }

    function test_Invariant_HookBalanceEqualsPendingAfterEachSwap() public {
        for (uint256 i = 0; i < 8; ++i) {
            _swapExactIn(i % 2 == 0, SWAP_AMOUNT);

            assertEq(usdc.balanceOf(address(hook)), hook.pendingUSDC(), "USDC balance drifted from pendingUSDC");
            assertEq(weth.balanceOf(address(hook)), hook.pendingWETH(), "WETH balance drifted from pendingWETH");
        }
    }

    // Run past buffer capacity; observationCount must clamp at the buffer
    // size and head must wrap
    function test_ManySwaps_ObservationBufferSaturates() public {
        uint256 bufferSize = hook.OBSERVATION_BUFFER_SIZE();

        for (uint256 i = 0; i < bufferSize + 4; ++i) {
            _swapExactIn(i % 2 == 0, SWAP_AMOUNT);
        }

        assertEq(hook.observationCount(), bufferSize, "count clamps at buffer size");
        assertEq(hook.observationHead(), 4, "head wraps to 4 after bufferSize + 4 writes");
    }

    // Vol starts at 0, stays 0 after the first swap
    // then becomes non-zero from swap 2 onward.
    function test_VolatilityRises_AcrossSwapSequence() public {
        assertEq(hook.calculateVolatility(), 0, "vol starts at 0");

        _swapExactIn(true, SWAP_AMOUNT);
        assertEq(hook.calculateVolatility(), 0, "still 0 after first observation");

        _swapExactIn(false, SWAP_AMOUNT);
        uint256 volAfterTwo = hook.calculateVolatility();
        assertGt(volAfterTwo, 0, "two distinct prices -> non-zero vol");

        for (uint256 i = 0; i < 6; ++i) {
            _swapExactIn(i % 2 == 0, SWAP_AMOUNT);
        }
        assertGe(hook.calculateVolatility(), volAfterTwo, "vol monotone non-decreasing across the sequence");
    }

    // Premium rate starts at MIN (no observations) and stays within [MIN, MAX]
    // after any sequence of swaps
    function test_PremiumRate_NonDecreasing_AcrossSwapSequence() public {
        assertEq(hook.getPremiumRate(), hook.MIN_PREMIUM_BPS(), "starts at MIN");

        for (uint256 i = 0; i < 5; ++i) {
            _swapExactIn(i % 2 == 0, SWAP_AMOUNT);
        }
        uint256 rateAfter = hook.getPremiumRate();

        assertGe(rateAfter, hook.MIN_PREMIUM_BPS(), "never below MIN");
        assertLe(rateAfter, hook.MAX_PREMIUM_BPS(), "never above MAX");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";
import {BackstopHook} from "../../src/BackstopHook.sol";

/// @notice _afterAddLiquidity entry-state recording
contract BackstopHookEntryTrackingTest is BackstopFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    // Compute the same position key the hook uses internally
    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
    }

    function _addLiquidity(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
            }),
            ZERO_BYTES
        );
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

    // Adding liquidity to a previously-empty position should store the
    // current pool sqrt-price and the added liquidity
    function test_FirstAdd_RecordsRawEntryState() public {
        _addLiquidity(-60, 60, 1e17, bytes32(0));

        bytes32 key = _positionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));
        (uint160 entrySqrt, uint128 entryLiq) = hook.lpPositions(key);

        assertEq(entrySqrt, SQRT_PRICE_1_1, "entrySqrt should be current pool sqrt-price");
        assertEq(uint256(entryLiq), 1e17, "entryLiquidity == amount added");
    }

    // Adding more liquidity to an already-tracked position should:
    //  - sum the two liquidity contributions
    //  - liquidity-weighted-average the entry sqrt-price
    function test_SecondAdd_LiquidityWeightedAveragesEntry() public {
        // First add at price 1:1
        _addLiquidity(-60, 60, 1e17, bytes32(0));
        bytes32 key = _positionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));

        (uint160 sqrt1, uint128 liq1) = hook.lpPositions(key);

        // Move the pool price by swapping, then add more liquidity
        for (uint256 i = 0; i < 6; ++i) {
            _swapExactIn(true, 1e15);
        }

        // Read the new pool sqrt-price before the second add
        (uint160 currentSqrt,,,) = manager.getSlot0(poolKey.toId());

        _addLiquidity(-60, 60, 5e16, bytes32(0));

        (uint160 sqrtAfter, uint128 liqAfter) = hook.lpPositions(key);

        // Compute the same weighted average the hook should have written
        uint128 liq2 = 5e16;
        uint256 expectedSqrt = (uint256(sqrt1) * liq1 + uint256(currentSqrt) * liq2) / (uint256(liq1) + liq2);

        assertEq(uint256(sqrtAfter), expectedSqrt, "entry sqrt-price should be liquidity-weighted average");
        assertEq(uint256(liqAfter), uint256(liq1) + liq2, "entry liquidity should be the sum");
    }

    // Two adds to different tick ranges should land in different storage entries
    function test_DifferentRanges_TrackedAsDistinctPositions() public {
        _addLiquidity(-60, 60, 1e17, bytes32(0));
        _addLiquidity(-180, 180, 2e17, bytes32(0));

        bytes32 keyA = _positionKey(address(modifyLiquidityRouter), -60, 60, bytes32(0));
        bytes32 keyB = _positionKey(address(modifyLiquidityRouter), -180, 180, bytes32(0));

        (, uint128 liqA) = hook.lpPositions(keyA);
        (, uint128 liqB) = hook.lpPositions(keyB);

        assertEq(uint256(liqA), 1e17, "range A liquidity isolated");
        assertEq(uint256(liqB), 2e17, "range B liquidity isolated");
    }

    // Two adds to the same range but with different salts are different positions too
    function test_DifferentSalts_TrackedAsDistinctPositions() public {
        _addLiquidity(-60, 60, 1e17, bytes32(uint256(1)));
        _addLiquidity(-60, 60, 3e17, bytes32(uint256(2)));

        bytes32 key1 = _positionKey(address(modifyLiquidityRouter), -60, 60, bytes32(uint256(1)));
        bytes32 key2 = _positionKey(address(modifyLiquidityRouter), -60, 60, bytes32(uint256(2)));

        (, uint128 liq1) = hook.lpPositions(key1);
        (, uint128 liq2) = hook.lpPositions(key2);

        assertEq(uint256(liq1), 1e17, "salt 1 entry isolated");
        assertEq(uint256(liq2), 3e17, "salt 2 entry isolated");
    }
}

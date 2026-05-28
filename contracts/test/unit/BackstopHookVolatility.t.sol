// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BackstopHookHarness} from "../utils/BackstopHookHarness.sol";
import {IYieldVault} from "../../src/interfaces/IYieldVault.sol";
import {MockUSDCVault} from "../../src/vaults/MockUSDCVault.sol";
import {MockWETHVault} from "../../src/vaults/MockWETHVault.sol";

contract BackstopHookVolatilityTest is Test {
    BackstopHookHarness internal hook;

    //A sqrtPriceX96 used as the starting point for all observation sequences in these tests
    uint160 internal constant BASE_SQRT_PRICE = 2 ** 96;

    function setUp() public {
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 18);
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        MockUSDCVault usdcVault = new MockUSDCVault(IERC20(address(usdc)));
        MockWETHVault wethVault = new MockWETHVault(IERC20(address(weth)));

        // PoolManager isn't needed for math tests
        hook = new BackstopHookHarness(
            IPoolManager(address(0)),
            IERC20(address(usdc)),
            IERC20(address(weth)),
            IYieldVault(address(usdcVault)),
            IYieldVault(address(wethVault))
        );
    }

    // Empty + single-observation buffer

    // With no observations there are no consecutive pairs to difference, so vol must be zero
    function test_EmptyBuffer_ReturnsZeroVolAndMinPremium() public view {
        assertEq(hook.calculateVolatility(), 0, "empty buffer should report zero vol");
        assertEq(hook.getPremiumRate(), hook.MIN_PREMIUM_BPS(), "empty buffer should clamp to MIN premium");
    }

    // A single observation still yields zero pairs and zero vol
    function test_SingleObservation_ReturnsZeroVolAndMinPremium() public {
        hook.exposed_recordObservation(BASE_SQRT_PRICE);
        assertEq(hook.calculateVolatility(), 0, "one observation -> no pairs -> zero vol");
        assertEq(hook.getPremiumRate(), hook.MIN_PREMIUM_BPS());
    }

    // low vol so MIN premium

    /// Identical observations should report zero vol
    function test_StablePrices_ReturnZeroVolAndMinPremium() public {
        for (uint256 i = 0; i < 5; ++i) {
            hook.exposed_recordObservation(BASE_SQRT_PRICE);
        }
        assertEq(hook.calculateVolatility(), 0, "constant price stream -> zero vol");
        assertEq(hook.getPremiumRate(), hook.MIN_PREMIUM_BPS(), "premium should sit at MIN for calm pool");
    }

    // high vol so MAX premium

    /// Five observations, each does 10% on the sqrt-price
    function test_VolatilePrices_ReturnHighVolAndMaxPremium() public {
        uint160 high = uint160((uint256(BASE_SQRT_PRICE) * 110) / 100);
        hook.exposed_recordObservation(BASE_SQRT_PRICE);
        hook.exposed_recordObservation(high);
        hook.exposed_recordObservation(BASE_SQRT_PRICE);
        hook.exposed_recordObservation(high);
        hook.exposed_recordObservation(BASE_SQRT_PRICE);

        uint256 vol = hook.calculateVolatility();
        assertGt(vol, hook.VOL_BPS_HIGH(), "wild swings should overshoot VOL_BPS_HIGH");
        assertEq(hook.getPremiumRate(), hook.MAX_PREMIUM_BPS(), "premium should saturate at MAX");
    }

    // Premium curve bounds + linear interpolation

    // Pumping vol very high  must still cap the premium at MAX_PREMIUM_BPS
    function test_PremiumRate_ClampedAtMax_NotExceeded() public {
        uint160 double = BASE_SQRT_PRICE * 2;
        for (uint256 i = 0; i < hook.OBSERVATION_BUFFER_SIZE(); ++i) {
            hook.exposed_recordObservation(i % 2 == 0 ? BASE_SQRT_PRICE : double);
        }
        uint256 premium = hook.getPremiumRate();
        assertEq(premium, hook.MAX_PREMIUM_BPS(), "premium must clamp at MAX even with very high vol");
        assertLe(premium, hook.MAX_PREMIUM_BPS(), "premium must never exceed MAX");
    }

    // A precisely chosen pair of observations should land on a predictable
    // premium computed by hand
    function test_PremiumRate_ConvexCurve_HitsExpectedValue() public {
        // Two observations with second 5% above first so vol = 500
        // Convex: squared = 500² / 1000 = 250
        //         premium = 500 + (250 × 2500) / 1000 = 500 + 625 = 1125.
        uint160 plus5pct = uint160((uint256(BASE_SQRT_PRICE) * 105) / 100);
        hook.exposed_recordObservation(BASE_SQRT_PRICE);
        hook.exposed_recordObservation(plus5pct);

        assertApproxEqAbs(hook.calculateVolatility(), 500, 1, "single ~5% step -> vol ~= 500 bps");
        assertApproxEqAbs(hook.getPremiumRate(), 1_125, 5, "convex curve at vol~500 should yield ~1125 bps");
    }

    // Vol very close to but below VOL_BPS_HIGH should yield a premium very
    // close to but below MAX.
    function test_PremiumRate_JustBelowSaturation_StaysUnderMax() public {
        uint160 plus9pct = uint160((uint256(BASE_SQRT_PRICE) * 109) / 100);
        hook.exposed_recordObservation(BASE_SQRT_PRICE);
        hook.exposed_recordObservation(plus9pct);

        assertApproxEqAbs(hook.calculateVolatility(), 900, 1);
        assertApproxEqAbs(hook.getPremiumRate(), 2_525, 5);
        assertLt(hook.getPremiumRate(), hook.MAX_PREMIUM_BPS(), "must still sit below the MAX clamp");
    }

    // Circular buffer

    // Pushing more observations than the buffer can hold should make old
    // observations age out
    function test_CircularBuffer_OldObservationsExpire() public {
        uint160 high = uint160((uint256(BASE_SQRT_PRICE) * 120) / 100);

        // create high vol
        for (uint256 i = 0; i < hook.OBSERVATION_BUFFER_SIZE(); ++i) {
            hook.exposed_recordObservation(i % 2 == 0 ? BASE_SQRT_PRICE : high);
        }
        uint256 volWhenSpiky = hook.calculateVolatility();
        assertGt(volWhenSpiky, 0, "spiky fill should produce non-zero vol");

        // now flood to create a flat vol
        for (uint256 i = 0; i < hook.OBSERVATION_BUFFER_SIZE(); ++i) {
            hook.exposed_recordObservation(BASE_SQRT_PRICE);
        }
        assertEq(hook.calculateVolatility(), 0, "after flooding with flat prices vol should drop to zero");
    }
}

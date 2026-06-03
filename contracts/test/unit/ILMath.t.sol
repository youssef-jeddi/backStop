// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ILMath} from "../../src/libraries/ILMath.sol";

/// @notice Unit tests of the IL closed form formula
contract ILMathTest is Test {
    /// price 1:1 so sqrtPrice = 2^96
    uint160 internal constant SQRT_P_1 = 79_228_162_514_264_337_593_543_950_336;

    /// price 2:1 so sqrtPrice = √2 * 2^96
    uint160 internal constant SQRT_P_2 = 112_045_541_949_572_279_837_463_876_454;

    /// price 4:1 so sqrtPrice = 2 * 2^96 = 2^97
    uint160 internal constant SQRT_P_4 = 158_456_325_028_528_675_187_087_900_672;

    /// price 10:1 so sqrtPrice = √10 · 2^96
    uint160 internal constant SQRT_P_10 = 250_539_826_180_810_712_802_068_716_950;

    /// price 1:2 so sqrtPrice = 2^96 / √2
    uint160 internal constant SQRT_P_HALF = 56_022_770_974_786_139_918_731_938_227;

    // IL is zero by construction when the LP exits at the same price they entered
    function test_PriceUnchanged_IL_IsZero() public pure {
        assertEq(ILMath.computeIL(SQRT_P_1, SQRT_P_1), 0, "same price -> IL = 0");
        assertEq(ILMath.computeIL(SQRT_P_4, SQRT_P_4), 0, "same price -> IL = 0 (at any level)");
    }

    // price 4x so IL = 1/5
    function test_Price4x_IL_IsExactly2000Bps() public pure {
        assertEq(ILMath.computeIL(SQRT_P_1, SQRT_P_4), 2000, "price 4x -> IL = exactly 2000 bps");
    }

    // Price 0.5x: should produce the same IL as price 2x by symmetry
    // Confirms the formula handles both directions .
    function test_PriceHalves_IL_IsApprox572Bps_AndSymmetricWith2x() public pure {
        uint256 ilHalve = ILMath.computeIL(SQRT_P_1, SQRT_P_HALF);
        uint256 il2x = ILMath.computeIL(SQRT_P_1, SQRT_P_2);

        assertApproxEqAbs(ilHalve, 572, 2, "price 0.5x -> IL ~= 572 bps");
        assertApproxEqAbs(ilHalve, il2x, 2, "IL must be symmetric: f(2x) == f(0.5x)");
    }

    // Price 10x: IL = ~4250 bps.
    function test_Price10x_IL_IsApprox4250Bps() public pure {
        uint256 il = ILMath.computeIL(SQRT_P_1, SQRT_P_10);
        assertApproxEqAbs(il, 4250, 10, "price 10x -> IL ~= 4250 bps");
    }

    // Near-zero IL for tiny price moves
    function test_VerySmallMove_IL_IsNearZero() public pure {
        // entry × 1.001
        uint160 exitClose = uint160((uint256(SQRT_P_1) * 1001) / 1000);
        uint256 il = ILMath.computeIL(SQRT_P_1, exitClose);
        assertLt(il, 5, "0.1% sqrt move -> IL must be sub-5 bps");
    }

    // Degenerate inputs
    function test_ZeroInputs_ReturnZero_WithoutReverting() public pure {
        assertEq(ILMath.computeIL(0, SQRT_P_1), 0, "zero entry -> 0");
        assertEq(ILMath.computeIL(SQRT_P_1, 0), 0, "zero exit -> 0");
        assertEq(ILMath.computeIL(0, 0), 0, "both zero -> 0");
    }
}

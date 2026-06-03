// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Computes impermanent loss in bps for an LP
///         position given its entry and exit sqrt-prices.
///
/// @dev Closed-form IL from the standard derivation:
///
///        IL = 1 - 2·√r / (1 + r),   where r = exitPrice / entryPrice
///
///      Rewriting in terms of the sqrt-prices a = entrySqrt, b = exitSqrt
///      (so r = b²/a²) and simplifying:
///
///        IL = (a - b)² / (a² + b²)
library ILMath {
    // Fixed-point scale used to normalize input sqrt-prices
    uint256 internal constant SCALE = 1 << 96;

    /// @notice Returns the IL of an LP position in basis points
    function computeIL(uint160 entrySqrtPriceX96, uint160 exitSqrtPriceX96) internal pure returns (uint256 ilBps) {
        // Avoid division by 0
        if (entrySqrtPriceX96 == 0 || exitSqrtPriceX96 == 0) return 0;
        if (entrySqrtPriceX96 == exitSqrtPriceX96) return 0;

        uint256 a = uint256(entrySqrtPriceX96);
        uint256 b = uint256(exitSqrtPriceX96);
        uint256 m = a > b ? a : b;

        // Normalize
        uint256 an = FullMath.mulDiv(a, SCALE, m);
        uint256 bn = FullMath.mulDiv(b, SCALE, m);

        uint256 delta;
        unchecked {
            delta = an > bn ? an - bn : bn - an;
        }

        uint256 deltaSq = delta * delta;
        uint256 sumSq = an * an + bn * bn;

        ilBps = (10_000 * deltaSq) / sumSq;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {BackstopHook} from "../../src/BackstopHook.sol";
import {IYieldVault} from "../../src/interfaces/IYieldVault.sol";

/// @notice Test-only subclass that exposes BackstopHook's internal helpers
contract BackstopHookHarness is BackstopHook {
    constructor(IPoolManager _poolManager, IERC20 _usdc, IERC20 _weth, IYieldVault _usdcVault, IYieldVault _wethVault)
        BackstopHook(_poolManager, _usdc, _weth, _usdcVault, _wethVault)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function exposed_recordObservation(uint160 sqrtPriceX96) external {
        recordObservation(sqrtPriceX96);
    }
}

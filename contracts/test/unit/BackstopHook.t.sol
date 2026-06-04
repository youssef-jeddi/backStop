// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {BackstopFixture} from "../utils/BackstopFixture.sol";
import {BackstopHook} from "../../src/BackstopHook.sol";
import {IYieldVault} from "../../src/interfaces/IYieldVault.sol";

contract BackstopHookDeployTest is BackstopFixture {
    function test_HookAddressEncodesPermissionFlags() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(addressBits), uint256(HOOK_FLAGS), "low 14 bits of hook address != declared permissions");
    }

    // getHookPermissions struct must match the brief
    function test_GetHookPermissions_MatchesTheEnabledSet() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        // Enabled
        assertTrue(p.afterAddLiquidity, "afterAddLiquidity should be enabled");
        assertTrue(p.afterRemoveLiquidity, "afterRemoveLiquidity should be enabled");
        assertTrue(p.afterSwap, "afterSwap should be enabled");
        assertTrue(p.beforeSwap, "beforeSwap should be enabled (dynamic-fee override)");
        assertTrue(p.afterSwapReturnDelta, "afterSwapReturnDelta should be enabled (premium take)");

        // Disabled
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity should be off");
        assertFalse(p.beforeInitialize, "beforeInitialize should be off");
        assertFalse(p.afterInitialize, "afterInitialize should be off");
        assertFalse(p.beforeRemoveLiquidity, "beforeRemoveLiquidity should be off");
        assertFalse(p.beforeDonate, "beforeDonate should be off");
        assertFalse(p.afterDonate, "afterDonate should be off");
    }

    // Deploying to a wrong address must revert
    function test_RevertWhen_DeployedAtWrongAddress() public {
        vm.expectRevert();
        deployCodeTo(
            "BackstopHook.sol",
            abi.encode(
                manager,
                IERC20(address(usdc)),
                IERC20(address(weth)),
                IYieldVault(address(usdcVault)),
                IYieldVault(address(wethVault))
            ),
            address(0xDEADBEEF)
        );
    }
}

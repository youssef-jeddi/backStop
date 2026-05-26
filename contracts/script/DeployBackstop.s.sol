// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {HelperConfig} from "./HelperConfig.s.sol";
import {BackstopHook} from "../src/BackstopHook.sol";
import {IYieldVault} from "../src/interfaces/IYieldVault.sol";
import {MockUSDCVault} from "../src/vaults/MockUSDCVault.sol";
import {MockWETHVault} from "../src/vaults/MockWETHVault.sol";

contract DeployBackstop is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Hook permissions BackstopHook enables
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG
    );

    function run()
        external
        returns (BackstopHook hook, MockUSDCVault usdcVault, MockWETHVault wethVault, HelperConfig helperConfig)
    {
        return deploy();
    }

    function deploy()
        public
        returns (BackstopHook hook, MockUSDCVault usdcVault, MockWETHVault wethVault, HelperConfig helperConfig)
    {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        // Vaults
        vm.startBroadcast();
        usdcVault = new MockUSDCVault(IERC20(config.usdc));
        wethVault = new MockWETHVault(IERC20(config.weth));
        vm.stopBroadcast();

        // Hook: mine + deploy
        bytes memory constructorArgs = abi.encode(
            IPoolManager(config.poolManager),
            IERC20(config.usdc),
            IERC20(config.weth),
            IYieldVault(address(usdcVault)),
            IYieldVault(address(wethVault))
        );

        (address minedAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(BackstopHook).creationCode, constructorArgs);

        vm.startBroadcast();
        hook = new BackstopHook{salt: salt}(
            IPoolManager(config.poolManager),
            IERC20(config.usdc),
            IERC20(config.weth),
            IYieldVault(address(usdcVault)),
            IYieldVault(address(wethVault))
        );
        vm.stopBroadcast();

        require(address(hook) == minedAddress, "DeployBackstop: hook address != mined address");
    }
}

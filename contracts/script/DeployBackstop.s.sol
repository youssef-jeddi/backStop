// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
        Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run()
        external
        returns (
            BackstopHook hook,
            MockUSDCVault usdcVault,
            MockWETHVault wethVault,
            HelperConfig helperConfig,
            PoolKey memory poolKey
        )
    {
        return deploy();
    }

    function deploy()
        public
        returns (
            BackstopHook hook,
            MockUSDCVault usdcVault,
            MockWETHVault wethVault,
            HelperConfig helperConfig,
            PoolKey memory poolKey
        )
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

        // Pool: build key with sorted currencies, initialize at config sqrt-price
        (Currency currency0, Currency currency1) = config.usdc < config.weth
            ? (Currency.wrap(config.usdc), Currency.wrap(config.weth))
            : (Currency.wrap(config.weth), Currency.wrap(config.usdc));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: config.swapFee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        vm.startBroadcast();
        IPoolManager(config.poolManager).initialize(poolKey, config.startingSqrtPriceX96);
        vm.stopBroadcast();

        // ── Log deployed addresses for frontend wiring ─────────────────────
        console2.log("===== BackStop deployment =====");
        console2.log("PoolManager (canonical) :", config.poolManager);
        console2.log("BackstopHook            :", address(hook));
        console2.log("USDC token              :", config.usdc);
        console2.log("WETH token              :", config.weth);
        console2.log("USDC vault              :", address(usdcVault));
        console2.log("WETH vault              :", address(wethVault));
        console2.log("usdc is currency0?      :", config.usdc < config.weth);
        console2.log("===============================");
    }
}

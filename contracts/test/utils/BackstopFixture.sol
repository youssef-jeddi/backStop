// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BackstopHook} from "../../src/BackstopHook.sol";
import {IYieldVault} from "../../src/interfaces/IYieldVault.sol";
import {MockUSDCVault} from "../../src/vaults/MockUSDCVault.sol";
import {MockWETHVault} from "../../src/vaults/MockWETHVault.sol";

// Shared test scaffold for every BackstopHook test suite
abstract contract BackstopFixture is Test, Deployers {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    address internal constant HOOK_ADDRESS = address(HOOK_FLAGS);

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockUSDCVault internal usdcVault;
    MockWETHVault internal wethVault;
    BackstopHook internal hook;

    PoolKey internal poolKey;
    bool internal usdcIsToken0;

    uint256 internal constant SEED_BALANCE = 1_000_000 ether;

    uint24 internal constant POOL_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant POOL_TICK_SPACING = 60;
    uint24 internal constant TARGET_TOTAL_FEE_PIPS = 3_000;

    function setUp() public virtual {
        // 1. v4 manager + every periphery test router we might want.
        deployFreshManagerAndRouters();

        // 2. Pool mock tokens
        usdc = new MockERC20("Mock USDC", "mUSDC", 18);
        weth = new MockERC20("Mock WETH", "mWETH", 18);

        // 3. Seed
        usdc.mint(address(this), SEED_BALANCE);
        weth.mint(address(this), SEED_BALANCE);

        // 4. Vaults
        usdcVault = new MockUSDCVault(IERC20(address(usdc)));
        wethVault = new MockWETHVault(IERC20(address(weth)));
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);

        usdcVault = new MockUSDCVault(IERC20(address(usdc)));
        wethVault = new MockWETHVault(IERC20(address(weth)));

        // 5. Deploy the hook
        deployCodeTo(
            "BackstopHook.sol",
            abi.encode(
                manager,
                IERC20(address(usdc)),
                IERC20(address(weth)),
                IYieldVault(address(usdcVault)),
                IYieldVault(address(wethVault))
            ),
            HOOK_ADDRESS
        );
        hook = BackstopHook(HOOK_ADDRESS);

        // 6. Build the pool key
        usdcIsToken0 = address(usdc) < address(weth);
        (Currency currency0, Currency currency1) = usdcIsToken0
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(usdc)));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // 7. Initialize the pool at a 1:1 sqrt-price
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // 8. Seed initial liquidity
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.label(address(manager), "PoolManager");
        vm.label(address(usdc), "mUSDC");
        vm.label(address(weth), "mWETH");
        vm.label(address(usdcVault), "MockUSDCVault");
        vm.label(address(wethVault), "MockWETHVault");
        vm.label(address(hook), "BackstopHook");
    }
}

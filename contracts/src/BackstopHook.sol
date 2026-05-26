// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IYieldVault} from "./interfaces/IYieldVault.sol";

contract BackstopHook is BaseHook {
    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IYieldVault public immutable usdcVault;
    IYieldVault public immutable wethVault;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Threshold for IL payout 1%
    uint256 public constant IL_THRESHOLD_BPS = 100;
    // Share of underwriter capital held liquid for instant claims 20%
    uint256 public constant BUFFER_RATIO_BPS = 2_000;
    // Minimum premium
    uint256 public constant MIN_PREMIUM_BPS = 500;
    // Maximum premium
    uint256 public constant MAX_PREMIUM_BPS = 3_000;
    // Size of the observation buffer used to estimate realized volatility
    uint256 public constant OBSERVATION_BUFFER_SIZE = 16;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Premium fees collected from swaps but not yet swept into the yield vaults
    uint256 public pendingUSDC;
    uint256 public pendingWETH;
    // Liquid USDC/WETH, we take from here first when paying IL claims before falling back to vault withdrawals
    uint256 public liquidBufferUSDC;
    uint256 public liquidBufferWETH;
    // underwriter share balance
    mapping(address underwriter => uint256 shares) public usdcUnderwriterShares;
    mapping(address underwriter => uint256 shares) public wethUnderwriterShares;
    // Total shares for each underwriting pool
    uint256 public totalUSDCUnderwriterShares;
    uint256 public totalWETHUnderwriterShares;

    // Snapshot that is later used to calculate IL
    struct LPPosition {
        uint160 entrySqrtPriceX96;
        uint128 entryLiquidity;
    }
    // Map of LP positions, keyed by : owner, tickLower, tickUpper, salt
    mapping(bytes32 positionKey => LPPosition) public lpPositions;
    // Recent sqrtPriceX96 observations
    uint160[OBSERVATION_BUFFER_SIZE] public observations;
    // Next slot to write in the circular buffer
    uint256 public observationHead;
    // Total observations recorded
    uint256 public observationCount;

    uint256 public totalPremiumsAccumulatedUSDC;
    uint256 public totalPremiumsAccumulatedWETH;
    uint256 public totalClaimsPaidUSDC;
    uint256 public totalClaimsPaidWETH;
    uint256 public immutable poolStartTimestamp;

    /// @notice Time conversion for annualizing lifetime accumulators. Uses
    ///         the 365-day "trading year" approximation — close enough for
    ///         demo APY displays.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolTokenMismatch();
    error VaultAssetMismatch();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event UnderwriterDeposited(
        address indexed underwriter, address indexed token, uint256 amountIn, uint256 sharesMinted
    );
    event UnderwriterWithdrew(
        address indexed underwriter, address indexed token, uint256 sharesBurned, uint256 amountOut
    );
    event PremiumAccrued(address indexed token, uint256 amount, uint256 premiumRateBps);
    event SweptToVaults(uint256 usdcToVault, uint256 wethToVault, uint256 usdcToBuffer, uint256 wethToBuffer);
    event ILClaimPaid(address indexed lp, uint256 ilBps, uint256 usdcPayout, uint256 wethPayout);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager, IERC20 _usdc, IERC20 _weth, IYieldVault _usdcVault, IYieldVault _wethVault)
        BaseHook(_poolManager)
    {
        usdc = _usdc;
        weth = _weth;
        usdcVault = _usdcVault;
        wethVault = _wethVault;
        poolStartTimestamp = block.timestamp;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice After every add-liquidity: snapshot the LP's entry sqrt-price
    ///         and liquidity into lpPositions.
    ///         _afterRemoveLiquidity uses this snapshot to compute IL versus
    ///         the price the LP first added at.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice After every remove-liquidity: look up the LP's entry snapshot,
    ///         compute IL against the current price, and pay out the LP from
    ///         the underwriting reserves if IL crosses IL_THRESHOLD_BPS.
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /*
        /// @notice Before each swap: compute today's premium rate from current
        ///         vol and override the pool's LP fee to leave room for the
        ///         hook's share.
        function _beforeSwap(
            address,
            PoolKey calldata,
            SwapParams calldata,
            bytes calldata
        )
        {

        }
    */

    /// @notice After each swap: physically claim the underwriter premium from
    ///         the pool, route it to the matching pending reserve, then push
    ///         the post-swap sqrt-price into the observation buffer.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, int128(0));
    }
}

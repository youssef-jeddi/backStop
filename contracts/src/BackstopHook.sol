// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IYieldVault} from "./interfaces/IYieldVault.sol";

contract BackstopHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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
    // Total fee the trader experiences on every swap
    uint24 public constant TARGET_TOTAL_FEE_PIPS = 3_000;
    // Cumulative-volatility value (in bps)
    uint256 public constant VOL_BPS_HIGH = 1_000;
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
    uint256 public totalVaultUSDCDeposited;
    uint256 public totalVaultWETHDeposited;
    uint256 public totalVaultUSDCWithdrawn;
    uint256 public totalVaultWETHWithdrawn;
    uint256 public immutable poolStartTimestamp;

    /// @notice Time conversion for annualizing lifetime accumulators
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolTokenMismatch();
    error VaultAssetMismatch();
    error UnsupportedToken(address token);
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();

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

        // Vaults are trusted (set at construction and immutable)
        _usdc.approve(address(_usdcVault), type(uint256).max);
        _weth.approve(address(_wethVault), type(uint256).max);
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
    ///         and liquidity into lpPositions
    ///         _afterRemoveLiquidity uses this snapshot to compute IL versus
    ///         the price the LP first added at
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 posKey = _positionKey(sender, params.tickLower, params.tickUpper, params.salt);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 added = uint128(uint256(params.liquidityDelta));

        LPPosition storage pos = lpPositions[posKey];
        if (pos.entryLiquidity == 0) {
            pos.entrySqrtPriceX96 = sqrtPriceX96;
            pos.entryLiquidity = added;
        } else {
            uint256 totalLiq = uint256(pos.entryLiquidity) + added;
            uint256 weighted =
                (uint256(pos.entrySqrtPriceX96) * pos.entryLiquidity + uint256(sqrtPriceX96) * added) / totalLiq;
            pos.entrySqrtPriceX96 = uint160(weighted);
            pos.entryLiquidity = uint128(totalLiq);
        }

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

    /// @notice Before each swap: compute today's premium rate from current
    ///         vol and override the pool's LP fee to leave room for the
    ///         hook's share.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 premiumRateBps = getPremiumRate();

        // LP gets TARGET × (1 - premiumRate)
        // hook will claim the rest in _afterSwap.
        uint24 lpFeePips = uint24((uint256(TARGET_TOTAL_FEE_PIPS) * (10_000 - premiumRateBps)) / 10_000);
        uint24 lpFeeOverride = lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /// @notice After each swap: physically claim the underwriter premium from
    ///         the pool, route it to the matching pending reserve, then push
    ///         the post-swap sqrt-price into the observation buffer.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 premiumRateBps = getPremiumRate();
        uint256 hookClaim;

        {
            uint256 hookSharePips = (uint256(TARGET_TOTAL_FEE_PIPS) * premiumRateBps) / 10_000;

            // Find the unspecified side cause v4 only allows the hook to touch
            // the currency the trader didn't specify
            bool unspecifiedIsCurrency1 = params.zeroForOne == (params.amountSpecified < 0);
            Currency unspecifiedCurrency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
            int128 unspecifiedDelta = unspecifiedIsCurrency1 ? delta.amount1() : delta.amount0();

            uint256 unspecifiedMag =
                unspecifiedDelta >= 0 ? uint256(uint128(unspecifiedDelta)) : uint256(uint128(-unspecifiedDelta));

            hookClaim = (unspecifiedMag * hookSharePips) / 1_000_000;

            if (hookClaim > 0) {
                // Pull real tokens from PoolManager
                poolManager.take(unspecifiedCurrency, address(this), hookClaim);
                _routePremium(unspecifiedCurrency, hookClaim, premiumRateBps);
            }
        }

        // Record observation last
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        recordObservation(sqrtPriceX96);

        return (BaseHook.afterSwap.selector, int128(int256(hookClaim)));
    }

    /*//////////////////////////////////////////////////////////////
                VOLATILITY AND DYNAMIC PREMIUM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Push the current sqrtPriceX96 into the observation buffer.
    function recordObservation(uint160 sqrtPriceX96) internal {
        observations[observationHead] = sqrtPriceX96;
        observationHead = (observationHead + 1) % OBSERVATION_BUFFER_SIZE;
        if (observationCount < OBSERVATION_BUFFER_SIZE) {
            unchecked {
                observationCount++;
            }
        }
    }

    /// @notice Calculates the volatility
    function calculateVolatility() public view returns (uint256 vol) {
        uint256 count = observationCount;
        // Need at least two observations
        if (count < 2) return 0;

        uint256 bufferSize = OBSERVATION_BUFFER_SIZE;
        // Start at the oldest observation
        uint256 startIdx = (observationHead + bufferSize - count) % bufferSize;

        for (uint256 i = 1; i < count; ++i) {
            uint160 prev = observations[(startIdx + i - 1) % bufferSize];
            uint160 curr = observations[(startIdx + i) % bufferSize];
            uint160 delta;
            unchecked {
                delta = curr > prev ? curr - prev : prev - curr;
            }
            if (prev != 0) {
                vol += (uint256(delta) * 10_000) / uint256(prev);
            }
        }
    }

    /// @notice Maps the volatilty onto a premium share of swap fees
    function getPremiumRate() public view returns (uint256) {
        uint256 vol = calculateVolatility();
        if (vol >= VOL_BPS_HIGH) return MAX_PREMIUM_BPS;

        uint256 squared = (vol * vol) / VOL_BPS_HIGH;
        return MIN_PREMIUM_BPS + (squared * (MAX_PREMIUM_BPS - MIN_PREMIUM_BPS)) / VOL_BPS_HIGH;
    }

    /*//////////////////////////////////////////////////////////////
                        UNDERWRITERS OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit 'amount' of 'token' into the matching underwriting pool
    ///         and receive proportional shares
    function depositAsUnderwriter(address token, uint256 amount) external returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        _sweep();

        uint256 nav;
        uint256 totalSharesOutstanding;
        if (token == address(usdc)) {
            nav = _navUSDC();
            totalSharesOutstanding = totalUSDCUnderwriterShares;
        } else if (token == address(weth)) {
            nav = _navWETH();
            totalSharesOutstanding = totalWETHUnderwriterShares;
        } else {
            revert UnsupportedToken(token);
        }

        shares = (totalSharesOutstanding == 0 || nav == 0) ? amount : (amount * totalSharesOutstanding) / nav;
        if (shares == 0) revert ZeroAmount();

        if (token == address(usdc)) {
            usdcUnderwriterShares[msg.sender] += shares;
            totalUSDCUnderwriterShares = totalSharesOutstanding + shares;
            liquidBufferUSDC += amount;
            usdc.transferFrom(msg.sender, address(this), amount);
            emit UnderwriterDeposited(msg.sender, address(usdc), amount, shares);
            _rebalanceUSDC();
        } else {
            wethUnderwriterShares[msg.sender] += shares;
            totalWETHUnderwriterShares = totalSharesOutstanding + shares;
            liquidBufferWETH += amount;
            weth.transferFrom(msg.sender, address(this), amount);
            emit UnderwriterDeposited(msg.sender, address(weth), amount, shares);
            _rebalanceWETH();
        }
    }

    /// @notice Burn 'shares' and receive the proportional amount of 'token'
    function withdrawAsUnderwriter(address token, uint256 shares) external returns (uint256 amountOut) {
        if (shares == 0) revert ZeroShares();
        _sweep();

        if (token == address(usdc)) {
            amountOut = _withdrawUSDC(shares);
        } else if (token == address(weth)) {
            amountOut = _withdrawWETH(shares);
        } else {
            revert UnsupportedToken(token);
        }
    }

    /// @notice Move accumulated swap-fee premium into the underwriting reserves
    ///         Permissionless function
    function sweepToVaults() external {
        _sweep();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _routePremium(Currency currency, uint256 amount, uint256 rateBps) internal {
        address token = Currency.unwrap(currency);
        if (token == address(usdc)) {
            pendingUSDC += amount;
            totalPremiumsAccumulatedUSDC += amount;
            emit PremiumAccrued(address(usdc), amount, rateBps);
        } else if (token == address(weth)) {
            pendingWETH += amount;
            totalPremiumsAccumulatedWETH += amount;
            emit PremiumAccrued(address(weth), amount, rateBps);
        }
    }

    function _sweep() internal {
        uint256 usdcToVault;
        uint256 wethToVault;
        uint256 usdcToBuffer;
        uint256 wethToBuffer;

        uint256 pUsdc = pendingUSDC;
        if (pUsdc > 0) {
            usdcToBuffer = (pUsdc * BUFFER_RATIO_BPS) / 10_000;
            usdcToVault = pUsdc - usdcToBuffer;
            pendingUSDC = 0;
            liquidBufferUSDC += usdcToBuffer;
            if (usdcToVault > 0) {
                usdcVault.deposit(usdcToVault);
                totalVaultUSDCDeposited += usdcToVault;
            }
        }

        uint256 pWeth = pendingWETH;
        if (pWeth > 0) {
            wethToBuffer = (pWeth * BUFFER_RATIO_BPS) / 10_000;
            wethToVault = pWeth - wethToBuffer;
            pendingWETH = 0;
            liquidBufferWETH += wethToBuffer;
            if (wethToVault > 0) {
                wethVault.deposit(wethToVault);
                totalVaultWETHDeposited += wethToVault;
            }
        }

        if (pUsdc > 0 || pWeth > 0) {
            emit SweptToVaults(usdcToVault, wethToVault, usdcToBuffer, wethToBuffer);
        }
    }

    function _withdrawUSDC(uint256 shares) internal returns (uint256 amountOut) {
        uint256 userShares = usdcUnderwriterShares[msg.sender];
        if (shares > userShares) revert InsufficientShares();

        uint256 totalSharesOutstanding = totalUSDCUnderwriterShares;
        amountOut = (shares * _navUSDC()) / totalSharesOutstanding;

        // Effects.
        usdcUnderwriterShares[msg.sender] = userShares - shares;
        totalUSDCUnderwriterShares = totalSharesOutstanding - shares;

        // Interactions: buffer first, vault for any shortfall.
        _ensureBufferUSDC(amountOut);
        liquidBufferUSDC -= amountOut;
        usdc.transfer(msg.sender, amountOut);
        emit UnderwriterWithdrew(msg.sender, address(usdc), shares, amountOut);
    }

    function _withdrawWETH(uint256 shares) internal returns (uint256 amountOut) {
        uint256 userShares = wethUnderwriterShares[msg.sender];
        if (shares > userShares) revert InsufficientShares();

        uint256 totalSharesOutstanding = totalWETHUnderwriterShares;
        amountOut = (shares * _navWETH()) / totalSharesOutstanding;

        wethUnderwriterShares[msg.sender] = userShares - shares;
        totalWETHUnderwriterShares = totalSharesOutstanding - shares;

        _ensureBufferWETH(amountOut);
        liquidBufferWETH -= amountOut;
        weth.transfer(msg.sender, amountOut);
        emit UnderwriterWithdrew(msg.sender, address(weth), shares, amountOut);
    }

    /// @notice Rebalance the USDC side to the target 20% buffer / 80% vault
    function _rebalanceUSDC() internal {
        uint256 buffer = liquidBufferUSDC;
        uint256 vaultHeld = _vaultAssetsHeldBy(usdcVault);
        uint256 nav = buffer + vaultHeld;
        if (nav == 0) return;

        uint256 targetBuffer = (nav * BUFFER_RATIO_BPS) / 10_000;

        if (buffer > targetBuffer) {
            uint256 excess = buffer - targetBuffer;
            liquidBufferUSDC = buffer - excess;
            usdcVault.deposit(excess);
            totalVaultUSDCDeposited += excess;
        } else if (buffer < targetBuffer) {
            uint256 shortfall = targetBuffer - buffer;
            uint256 sharesToBurn = _vaultSharesFor(usdcVault, shortfall);
            if (sharesToBurn > 0) {
                uint256 pulled = usdcVault.withdraw(sharesToBurn);
                liquidBufferUSDC += pulled;
                totalVaultUSDCWithdrawn += pulled;
            }
        }
    }

    function _rebalanceWETH() internal {
        uint256 buffer = liquidBufferWETH;
        uint256 vaultHeld = _vaultAssetsHeldBy(wethVault);
        uint256 nav = buffer + vaultHeld;
        if (nav == 0) return;

        uint256 targetBuffer = (nav * BUFFER_RATIO_BPS) / 10_000;

        if (buffer > targetBuffer) {
            uint256 excess = buffer - targetBuffer;
            liquidBufferWETH = buffer - excess;
            wethVault.deposit(excess);
            totalVaultWETHDeposited += excess;
        } else if (buffer < targetBuffer) {
            uint256 shortfall = targetBuffer - buffer;
            uint256 sharesToBurn = _vaultSharesFor(wethVault, shortfall);
            if (sharesToBurn > 0) {
                uint256 pulled = wethVault.withdraw(sharesToBurn);
                liquidBufferWETH += pulled;
                totalVaultWETHWithdrawn += pulled;
            }
        }
    }

    /// @notice Tops up the USDC buffer from the vault if needed to cover 'needed'
    function _ensureBufferUSDC(uint256 needed) internal {
        if (needed <= liquidBufferUSDC) return;
        uint256 shortfall = needed - liquidBufferUSDC;
        uint256 sharesToBurn = _vaultSharesFor(usdcVault, shortfall);
        uint256 pulled = usdcVault.withdraw(sharesToBurn);
        liquidBufferUSDC += pulled;
        totalVaultUSDCWithdrawn += pulled;
    }

    function _ensureBufferWETH(uint256 needed) internal {
        if (needed <= liquidBufferWETH) return;
        uint256 shortfall = needed - liquidBufferWETH;
        uint256 sharesToBurn = _vaultSharesFor(wethVault, shortfall);
        uint256 pulled = wethVault.withdraw(sharesToBurn);
        liquidBufferWETH += pulled;
        totalVaultWETHWithdrawn += pulled;
    }

    function _navUSDC() internal view returns (uint256) {
        return liquidBufferUSDC + _vaultAssetsHeldBy(usdcVault);
    }

    function _navWETH() internal view returns (uint256) {
        return liquidBufferWETH + _vaultAssetsHeldBy(wethVault);
    }

    /// @notice Hook's claim on the vault's underlying
    function _vaultAssetsHeldBy(IYieldVault vault) internal view returns (uint256) {
        uint256 ourShares = vault.balanceOf(address(this));
        if (ourShares == 0) return 0;
        uint256 totalSharesOutstanding = vault.totalShares();
        if (totalSharesOutstanding == 0) return 0;
        return (vault.totalAssets() * ourShares) / totalSharesOutstanding;
    }

    /// @notice Number of vault shares to burn to receive at least 'assetsNeeded'
    function _vaultSharesFor(IYieldVault vault, uint256 assetsNeeded) internal view returns (uint256) {
        uint256 totalAssets = vault.totalAssets();
        if (totalAssets == 0) return 0;
        uint256 totalSharesOutstanding = vault.totalShares();
        if (totalSharesOutstanding == 0) return 0;
        return (assetsNeeded * totalSharesOutstanding + totalAssets - 1) / totalAssets;
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
    }
}

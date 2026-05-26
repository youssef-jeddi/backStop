// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

abstract contract CodeConstants {
    // Chain IDs
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    // BackStop protocol parameters
    uint256 internal constant IL_THRESHOLD_BPS = 100; // 1% IL payout threshold
    uint256 internal constant BUFFER_RATIO_BPS = 2_000; // 20% liquid buffer share of premium
    uint256 internal constant MIN_PREMIUM_BPS = 500; // 5%
    uint256 internal constant MAX_PREMIUM_BPS = 3_000; // 30%

    // Source: https://developers.uniswap.org/contracts/v4/deployments
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant SEPOLIA_POOL_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address internal constant SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A;
}

/// @notice Per-chain deployment config in the Cyfrin pattern
contract HelperConfig is CodeConstants, Script {
    error InvalidChainId(uint256 chainId);

    struct NetworkConfig {
        address poolManager;
        address usdc;
        address weth;
    }

    NetworkConfig public localNetworkConfig;
    NetworkConfig public sepoliaNetworkConfig;

    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (chainId == LOCAL_CHAIN_ID) return getOrCreateAnvilConfig();
        if (chainId == SEPOLIA_CHAIN_ID) return getOrCreateSepoliaConfig();
        revert InvalidChainId(chainId);
    }

    /*//////////////////////////////////////////////////////////////
                              LOCAL ANVIL
    //////////////////////////////////////////////////////////////*/

    /// @notice Create the anvil config
    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (localNetworkConfig.poolManager != address(0)) {
            return localNetworkConfig;
        }

        vm.startBroadcast();
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 18);
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        PoolManager poolManager = new PoolManager(msg.sender);
        vm.stopBroadcast();

        localNetworkConfig =
            NetworkConfig({poolManager: address(poolManager), usdc: address(usdc), weth: address(weth)});
        return localNetworkConfig;
    }

    /*//////////////////////////////////////////////////////////////
                                SEPOLIA
    //////////////////////////////////////////////////////////////*/

    /// @notice Create the sepolia config
    function getOrCreateSepoliaConfig() public returns (NetworkConfig memory) {
        if (sepoliaNetworkConfig.usdc != address(0)) {
            return sepoliaNetworkConfig;
        }

        vm.startBroadcast();
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 18);
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        vm.stopBroadcast();

        sepoliaNetworkConfig =
            NetworkConfig({poolManager: SEPOLIA_POOL_MANAGER, usdc: address(usdc), weth: address(weth)});
        return sepoliaNetworkConfig;
    }
}

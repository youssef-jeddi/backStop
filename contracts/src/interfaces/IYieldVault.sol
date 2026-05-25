// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IYieldVault
interface IYieldVault {
    /// @notice Deposit `amount` of the underlying asset and mint shares to msg.sender
    function deposit(uint256 amount) external;

    /// @notice Burn `shares` from msg.sender and return the proportional asset payout
    function withdraw(uint256 shares) external returns (uint256 assetsOut);

    /// @notice Shares currently owned by `user`
    function balanceOf(address user) external view returns (uint256 shares);

    /// @notice Total underlying asset held by the vault
    function totalAssets() external view returns (uint256);

    /// @notice Total share supply across all depositors
    function totalShares() external view returns (uint256);

    /// @notice For the demo: simulate yield accrual without a strategy
    function simulateYield(uint256 basisPoints) external;
}

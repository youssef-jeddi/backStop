// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IYieldVault} from "../interfaces/IYieldVault.sol";
import {IMintableERC20} from "../interfaces/IMintableERC20.sol";

/// @title MockUSDCVault
contract MockUSDCVault is IYieldVault {
    IERC20 public immutable asset;

    uint256 public override totalShares;
    mapping(address => uint256) public override balanceOf;

    error ZeroAmount();
    error InsufficientShares();

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function deposit(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();

        uint256 _totalShares = totalShares;
        uint256 _totalAssets = totalAssets();

        // First depositor (or empty vault) mints 1:1, otherwise pro-rata against existing pool
        uint256 shares = (_totalShares == 0 || _totalAssets == 0) ? amount : (amount * _totalShares) / _totalAssets;

        balanceOf[msg.sender] += shares;
        totalShares = _totalShares + shares;

        asset.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 shares) external override returns (uint256 assetsOut) {
        if (shares == 0) revert ZeroAmount();

        uint256 userShares = balanceOf[msg.sender];
        if (shares > userShares) revert InsufficientShares();

        uint256 _totalShares = totalShares;
        assetsOut = (shares * totalAssets()) / _totalShares;

        balanceOf[msg.sender] = userShares - shares;
        totalShares = _totalShares - shares;

        asset.transfer(msg.sender, assetsOut);
    }

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @inheritdoc IYieldVault
    function simulateYield(uint256 basisPoints) external override {
        uint256 yieldAmount = (totalAssets() * basisPoints) / 10_000;
        if (yieldAmount > 0) {
            IMintableERC20(address(asset)).mint(address(this), yieldAmount);
        }
    }
}

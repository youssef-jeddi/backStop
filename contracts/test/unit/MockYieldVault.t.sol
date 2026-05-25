// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IYieldVault} from "../../src/interfaces/IYieldVault.sol";
import {MockUSDCVault} from "../../src/vaults/MockUSDCVault.sol";
import {MockWETHVault} from "../../src/vaults/MockWETHVault.sol";

/// @notice Shared behavior tests for any IYieldVault implementation
abstract contract MockYieldVaultBaseTest is Test {
    IYieldVault internal vault;
    MockERC20 internal asset;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    error ZeroAmount();
    error InsufficientShares();

    /// @dev Subclasses pick the asset (and its decimals) and the concrete vault
    function _deployVault() internal virtual returns (IYieldVault, MockERC20);

    function setUp() public virtual {
        (vault, asset) = _deployVault();

        // Fund both depositors
        uint256 seed = 1_000_000 * (10 ** asset.decimals());
        asset.mint(alice, seed);
        asset.mint(bob, seed);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Deposit accounting
    // ------------------------------------------------------------------

    // First depositor into an empty vault should mint shares 1:1
    function test_FirstDeposit_Mints1to1Shares() public {
        uint256 amount = 1_000 * (10 ** asset.decimals());

        vm.prank(alice);
        vault.deposit(amount);

        assertEq(vault.balanceOf(alice), amount, "first depositor: shares != assets");
        assertEq(vault.totalAssets(), amount, "totalAssets did not match deposit");
    }

    // A later depositor should receive shares pro-rata against the existing
    // totalShares / totalAssets ratio. Without yield, the ratio is
    // still 1:1 so the second deposit's shares should equal the assets in.
    function test_SubsequentDeposit_UsesProportionalRatio() public {
        uint256 firstAmount = 1_000 * (10 ** asset.decimals());
        uint256 secondAmount = 500 * (10 ** asset.decimals());

        vm.prank(alice);
        vault.deposit(firstAmount);

        vm.prank(bob);
        vault.deposit(secondAmount);

        assertEq(vault.balanceOf(bob), secondAmount, "bob shares should equal his deposit at 1:1 ratio");
        assertEq(vault.totalAssets(), firstAmount + secondAmount, "totalAssets miscounted");
    }

    // Two users at different deposit sizes should hold shares in the same
    // ratio as their contributions.
    function test_TwoUsers_GetProportionalShares() public {
        uint256 aliceAmount = 1_000 * (10 ** asset.decimals());
        uint256 bobAmount = 3_000 * (10 ** asset.decimals());

        vm.prank(alice);
        vault.deposit(aliceAmount);
        vm.prank(bob);
        vault.deposit(bobAmount);

        // Alice has 25% of pool, Bob has 75%.
        assertEq(vault.balanceOf(alice) * 3, vault.balanceOf(bob), "share ratio != deposit ratio");
    }

    // ------------------------------------------------------------------
    // Yield + withdraw
    // ------------------------------------------------------------------

    // simulateYield(bps) should mint directly into the vault, raising the shares value
    function test_SimulateYield_InflatesTotalAssets() public {
        uint256 amount = 1_000 * (10 ** asset.decimals());
        vm.prank(alice);
        vault.deposit(amount);

        // 5% yield
        // totalAssets = 1.05 times the deposit
        vault.simulateYield(500);

        assertEq(vault.totalAssets(), amount + (amount * 500) / 10_000, "5% yield not credited");
    }

    // Depositor who experiences vault yield should get principal + yield
    function test_Withdraw_ReturnsPrincipalPlusYield() public {
        uint256 amount = 1_000 * (10 ** asset.decimals());
        vm.prank(alice);
        vault.deposit(amount);

        vault.simulateYield(1_000); // 10%

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 balanceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 assetsOut = vault.withdraw(aliceShares);

        uint256 expected = amount + (amount * 1_000) / 10_000; // 1.10 * deposit
        assertEq(assetsOut, expected, "withdraw payout != principal + yield");
        assertEq(asset.balanceOf(alice) - balanceBefore, expected, "alice did not receive payout");
        assertEq(vault.balanceOf(alice), 0, "alice's shares should have been fully burned");
        assertEq(vault.totalAssets(), 0, "vault should be drained after sole depositor exits");
    }

    // Yield must accrue to existing share-holders in the same ratio they hold shares
    function test_Yield_DistributedProportionally() public {
        uint256 aliceAmount = 1_000 * (10 ** asset.decimals());
        uint256 bobAmount = 3_000 * (10 ** asset.decimals());

        vm.prank(alice);
        vault.deposit(aliceAmount);
        vm.prank(bob);
        vault.deposit(bobAmount);

        vault.simulateYield(1_000); // 10% on 4000 = 4400 totalAssets

        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        uint256 bobBalanceBefore = asset.balanceOf(bob);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);

        vm.prank(alice);
        uint256 alicePayout = vault.withdraw(aliceShares);
        vm.prank(bob);
        uint256 bobPayout = vault.withdraw(bobShares);

        assertEq(alicePayout, aliceAmount + (aliceAmount * 1_000) / 10_000, "alice yield share wrong");
        assertEq(bobPayout, bobAmount + (bobAmount * 1_000) / 10_000, "bob yield share wrong");
        assertEq(asset.balanceOf(alice) - aliceBalanceBefore, alicePayout);
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, bobPayout);
    }

    // Partial withdraws should leave the depositor with the remaining share of the vault
    function test_PartialWithdraw_LeavesProportionalShare() public {
        uint256 amount = 1_000 * (10 ** asset.decimals());
        vm.prank(alice);
        vault.deposit(amount);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 halfShares = aliceShares / 2;

        vm.prank(alice);
        uint256 assetsOut = vault.withdraw(halfShares);

        assertEq(assetsOut, amount / 2, "partial withdraw payout wrong");
        assertEq(vault.balanceOf(alice), aliceShares - halfShares, "alice's remaining shares wrong");
        assertEq(vault.totalAssets(), amount - assetsOut, "totalAssets did not update");
    }

    // ------------------------------------------------------------------
    // Revert paths
    // ------------------------------------------------------------------

    function test_RevertWhen_DepositIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_RevertWhen_WithdrawIsZero() public {
        uint256 amount = 1_000 * (10 ** asset.decimals());
        vm.prank(alice);
        vault.deposit(amount);

        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        vault.withdraw(0);
    }

    /// Trying to burn more shares than the caller owns should revert
    function test_RevertWhen_WithdrawExceedsBalance() public {
        uint256 amount = 1_000 * (10 ** asset.decimals());
        vm.prank(alice);
        vault.deposit(amount);

        vm.prank(alice);
        vm.expectRevert(InsufficientShares.selector);
        vault.withdraw(amount + 1);
    }
}

// ---------------------------------------------------------------------------
// Concrete bindings
// ---------------------------------------------------------------------------

contract MockUSDCVaultTest is MockYieldVaultBaseTest {
    function _deployVault() internal override returns (IYieldVault, MockERC20) {
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        MockUSDCVault v = new MockUSDCVault(IERC20(address(usdc)));
        vm.label(address(usdc), "mUSDC");
        vm.label(address(v), "MockUSDCVault");
        return (IYieldVault(address(v)), usdc);
    }
}

contract MockWETHVaultTest is MockYieldVaultBaseTest {
    function _deployVault() internal override returns (IYieldVault, MockERC20) {
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        MockWETHVault v = new MockWETHVault(IERC20(address(weth)));
        vm.label(address(weth), "mWETH");
        vm.label(address(v), "MockWETHVault");
        return (IYieldVault(address(v)), weth);
    }
}

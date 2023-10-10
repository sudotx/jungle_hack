// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20} from "../../lib/solmate/src/erc20/ERC20.sol";
import {SafeERC20} from "../../lib/solmate/src/erc20/SafeERC20.sol";
import {FixedPointMathLib} from "../../lib/solmate/src/utils/FixedPointMathLib.sol";

abstract contract Strategy is ERC20 {
    /// @notice Returns whether the strategy accepts ETH or an ERC20.
    /// @return True if the strategy accepts ETH, false otherwise.
    /// @dev Only present in Fuse cTokens, not Compound cTokens.
    function isCEther() external view virtual returns (bool);

    /// @notice Withdraws a specific amount of underlying tokens from the strategy.
    /// @param amount The amount of underlying tokens to withdraw.
    /// @return An error code, or 0 if the withdrawal was successful.
    function redeemUnderlying(uint256 amount) external virtual returns (uint256);

    /// @notice Returns a user's strategy balance in underlying tokens.
    /// @param user The user to get the underlying balance of.
    /// @return The user's strategy balance in underlying tokens.
    /// @dev May mutate the state of the strategy by accruing interest.
    function balanceOfUnderlying(address user) external virtual returns (uint256);
}

/// @notice Minimal interface for Vault strategies that accept ERC20s.
/// @dev Designed for out of the box compatibility with Fuse cERC20s.
abstract contract ERC20Strategy is Strategy {
    /// @notice Returns the underlying ERC20 token the strategy accepts.
    /// @return The underlying ERC20 token the strategy accepts.
    function underlying() external view virtual returns (ERC20);

    /// @notice Deposit a specific amount of underlying tokens into the strategy.
    /// @param amount The amount of underlying tokens to deposit.
    /// @return An error code, or 0 if the deposit was successful.
    function mint(uint256 amount) external virtual returns (uint256);
}

/// @title AssetmanagerMockStrategy
/// @notice This is essentially a malicious strategy that over-reports a user's balance
contract AssetManagerMockStrategy is ERC20("CV Mock Strategy", "cvsMOCK", 18), ERC20Strategy {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    /*///////////////////////////////////////////////////////////////
                        STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(ERC20 _underlying) {
        UNDERLYING = _underlying;

        BASE_UNIT = 10 ** _underlying.decimals();
    }

    function isCEther() external pure override returns (bool) {
        return false;
    }

    function underlying() external view override returns (ERC20) {
        return UNDERLYING;
    }

    function mint(uint256 amount) external override returns (uint256) {
        _mint(msg.sender, amount.fdiv(exchangeRate(), BASE_UNIT));

        UNDERLYING.safeTransferFrom(msg.sender, address(this), amount);

        return 0;
    }

    function redeemUnderlying(uint256 amount) external override returns (uint256) {
        _burn(msg.sender, amount.fdiv(exchangeRate(), BASE_UNIT));

        // !! ----------------------------------------- !! //
        // !! Mock Interest by Manipulating totalSupply !! //
        // !! ----------------------------------------- !! //
        // UNDERLYING.mint(address(this), 0.5e18);
        // !! ----------------------------------------- !! //

        UNDERLYING.safeTransfer(msg.sender, amount);

        return 0;
    }

    function balanceOfUnderlying(address user) external view override returns (uint256) {
        return balanceOf[user].fmul(exchangeRate(), BASE_UNIT);
    }

    /*///////////////////////////////////////////////////////////////
                            INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    // solhint-disable-next-line var-name-mixedcase
    ERC20 internal immutable UNDERLYING;

    // solhint-disable-next-line var-name-mixedcase
    uint256 internal immutable BASE_UNIT;

    function exchangeRate() internal view returns (uint256) {
        uint256 cTokenSupply = totalSupply;

        if (cTokenSupply == 0) return BASE_UNIT;

        return UNDERLYING.balanceOf(address(this)).fdiv(cTokenSupply, BASE_UNIT);
    }

    /*///////////////////////////////////////////////////////////////
                            MOCK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function simulateLoss(uint256 underlyingAmount) external {
        UNDERLYING.safeTransfer(address(0xDEAD), underlyingAmount);
    }
}

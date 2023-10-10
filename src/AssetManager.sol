// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Vault} from "vaults/Vault.sol";
import {Auth} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/erc20/ERC20.sol";
import {SafeERC20} from "solmate/erc20/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Vault} from "vaults/Vault.sol";

contract AssetManager is ERC20 {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;
    // storage variables //

    /// @dev we need to compose a Vault here because the Vault functions are external
    /// @dev which are not able to be overridden since that requires public virtual specifiers
    Vault public immutable VAULT;

    /// @notice The underlying token for the vault.
    ERC20 public immutable UNDERLYING;

    /// @notice the asset manager's payable address
    address payable public immutable ASSET_MANAGER;

    /// @notice the percent of the earned interest that should be redirected to the asset manager
    uint256 public immutable BASE_FEE;

    /// @notice One base unit of the underlying, and hence rvToken.
    /// @dev Will be equal to 10 ** UNDERLYING.decimals() which means
    /// if the token has 18 decimals ONE_WHOLE_UNIT will equal 10**18.
    uint256 public immutable BASE_UNIT;

    /// @notice Price per share of shareTokens at the last extraction
    uint256 public pricePerShareAtLastExtraction;

    /// @notice Total shareTokens earned by the Asset Manager at the last extraction
    uint256 public shareTokensEarnedByAssetManager;

    /// @notice Total shareTokens claimed by the Asset Manager
    uint256 public shareTokensClaimedByAssetManager;

    /// @notice Creates a new asset manager vault based on an underlying token.
    /// @param _UNDERLYING An underlying ERC20 compliant token.
    /// @param _ASSET_MANAGER The address of the asset manager
    /// @param _BASE_FEE The percent of earned interest to be routed to the asset manager
    /// @param _VAULT The existing/deployed Vault for the respective underlying token
    constructor(ERC20 _UNDERLYING, address payable _ASSET_MANAGER, uint256 _BASE_FEE, Vault _VAULT)
        // ex: Space DAI Managed Vault
        ERC20(
            string(abi.encodePacked("Space ", _UNDERLYING.name(), " Managed Vault")),
            // ex: shareDAI
            string(abi.encodePacked("share", _UNDERLYING.symbol())),
            // ex: 18
            _UNDERLYING.decimals()
        )
    {
        // Enforce BASE_FEE
        require(_BASE_FEE >= 0 && _BASE_FEE <= 100, "Fee Percent fails to meet [0, 100] bounds constraint.");

        // Define our immutables
        UNDERLYING = _UNDERLYING;
        ASSET_MANAGER = _ASSET_MANAGER;
        BASE_FEE = _BASE_FEE;
        VAULT = _VAULT;
        BASE_UNIT = 10 ** decimals;
    }

    /*///////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful deposit.
    /// @param user The address of the account that deposited into the vault.
    /// @param underlyingAmount The amount of underlying tokens that were deposited.
    /// @param vaultExchangeRate The current Vault exchange rate.
    /// @param sharevaultExchangeRate The current Vault exchange rate.
    event Deposit(
        address indexed user, uint256 underlyingAmount, uint256 vaultExchangeRate, uint256 sharevaultExchangeRate
    );

    /// @notice Emitted after a successful user withdrawal.
    /// @param user The address of the account that withdrew from the vault.
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    /// @param vaultExchangeRate The current Vault exchange rate.
    /// @param sharevaultExchangeRate The current Vault exchange rate.
    event Withdraw(
        address indexed user, uint256 underlyingAmount, uint256 vaultExchangeRate, uint256 sharevaultExchangeRate
    );

    /// @notice Emitted when a asset manager successfully withdraws their fee percent of earned interest.
    /// @param assetManager the address of the asset manager that withdrew - used primarily for indexing
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    /// @param vaultExchangeRate The current Vault exchange rate.
    /// @param sharevaultExchangeRate The current Vault exchange rate.
    event AssetManagerWithdraw(
        address indexed assetManager,
        uint256 underlyingAmount,
        uint256 vaultExchangeRate,
        uint256 sharevaultExchangeRate
    );

    /*///////////////////////////////////////////////////////////////
                        DEPOSIT AND WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit the vault's underlying token to mint vshareTokens
    /// @param underlyingAmount The amount of the underlying token to deposit
    function deposit(uint256 underlyingAmount) external {
        require(underlyingAmount != 0, "AMOUNT CANNOT BE ZERO");

        // Extract interest to asset manager
        extractInterestToAssetManager();

        // Fix exchange rates
        uint256 vaultEr = VAULT.exchangeRate();
        uint256 cVaultEr = vshareShareExchangeRate();

        // Determine the equivalent amount of rvTokens that will be minted to this asset manager vault.
        uint256 shareTokensToMint = underlyingAmount.fdiv(vaultEr, BASE_UNIT);
        _mint(msg.sender, shareTokensToMint.fdiv(cVaultEr, BASE_UNIT));
        emit Deposit(msg.sender, underlyingAmount, vaultEr, cVaultEr);

        // Transfer in UNDERLYING tokens from the sender to the vault
        UNDERLYING.safeApprove(address(VAULT), underlyingAmount);
        UNDERLYING.safeTransferFrom(msg.sender, address(this), underlyingAmount);

        // Deposit to the VAULT
        VAULT.deposit(underlyingAmount);
    }

    /// @notice Extracts and withdraws unclaimed interest earned by asset manager
    function withdrawInterestToAssetManager() external {
        // Extract interest to asset manager
        extractInterestToAssetManager();

        // Update claimed shareTokens
        uint256 shareTokenClaim = shareTokensEarnedByAssetManager - shareTokensClaimedByAssetManager;
        shareTokensClaimedByAssetManager = shareTokensEarnedByAssetManager;

        // Fix exchange rates
        uint256 vaultEr = VAULT.exchangeRate();
        uint256 cVaultEr = vshareShareExchangeRate();

        if (shareTokenClaim <= 0) return;

        uint256 withdrawUnderlyingAmount = shareTokenClaim.fmul(vaultEr, BASE_UNIT);

        /// Redeem and transfer
        VAULT.redeem(shareTokenClaim);
        UNDERLYING.safeTransfer(ASSET_MANAGER, withdrawUnderlyingAmount);

        // Pessimistic Event Emission
        emit AssetManagerWithdraw(msg.sender, withdrawUnderlyingAmount, vaultEr, cVaultEr);
    }

    /// @notice Withdraws a user's interest earned from the vault.
    /// @param withdrawalAmount The amount of the underlying token to withdraw.
    function withdraw(uint256 withdrawalAmount) external {
        require(withdrawalAmount != 0, "AMOUNT CANNOT BE ZERO");
        require(balanceOfUnderlying(msg.sender) >= withdrawalAmount, "INSUFFICIENT BALANCE");

        // Extract interest to asset manager
        extractInterestToAssetManager();

        // Fix Exchange Rates
        uint256 vaultEr = VAULT.exchangeRate();
        uint256 cVaultEr = vshareShareExchangeRate();

        // Calculate Token Amounts
        uint256 amountShareTokensToWithdraw = withdrawalAmount.fdiv(vaultEr, BASE_UNIT);
        uint256 amountVshareTokensToWithdraw = amountShareTokensToWithdraw.fdiv(cVaultEr, BASE_UNIT);

        // This will revert if the user does not have enough vshareTokens.
        _burn(msg.sender, amountVshareTokensToWithdraw);

        // Try to transfer balance to msg.sender
        VAULT.withdraw(withdrawalAmount);
        UNDERLYING.safeTransfer(msg.sender, withdrawalAmount);

        // Pessimistic Event Emition
        emit Withdraw(msg.sender, withdrawalAmount, vaultEr, cVaultEr);
    }

    /// @dev Do this before user deposits, user withdrawals, and asset manager withdrawals.
    function extractInterestToAssetManager() internal {
        uint256 pricePerShareNow = VAULT.exchangeRate();

        if (pricePerShareAtLastExtraction == 0) {
            pricePerShareAtLastExtraction = pricePerShareNow;
            return;
        }

        shareTokensEarnedByAssetManager += shareTokensToAssetManagerSinceLastExtraction(pricePerShareNow);
        pricePerShareAtLastExtraction = pricePerShareNow;
    }

    /// @notice Calculates the amount of shareTokens to extract to the asset manager since the last extraction
    /// @dev Pass in a pre-fetched price per share to prevent contentions
    /// @param pricePerShareNow The vault exchange rate
    /// @return The amount of shareTokens earned by a the asset manager since the last extraction as a uint256
    function shareTokensToAssetManagerSinceLastExtraction(uint256 pricePerShareNow) internal view returns (uint256) {
        // If pricePerShareNow <= pricePerShareAtLastExtraction, return 0
        if (pricePerShareNow <= pricePerShareAtLastExtraction) return 0;

        // Get amount of underlying tokens earned by vault users since last extraction
        // (before subtracting the quantity going to the asset manager)
        uint256 underlyingEarnedByUsersSinceLastExtraction = shareTokensOwnedByUsersAtLastExtraction().fmul(
            (pricePerShareNow - pricePerShareAtLastExtraction), BASE_UNIT
        );

        // Get the amount of underlying to be directed to asset manager
        /// @dev need to divide by 100 since BASE_FEE is a percent
        /// @dev represented as whole numbers (i.e. 0.10 or 10% is a BASE_FEE=10)
        uint256 underlyingToAssetManager = (underlyingEarnedByUsersSinceLastExtraction * BASE_FEE) / 100;

        underlyingToAssetManager += (shareTokensEarnedByAssetManager - shareTokensClaimedByAssetManager).fmul(
            (pricePerShareNow - pricePerShareAtLastExtraction), BASE_UNIT
        );

        return underlyingToAssetManager.fdiv(pricePerShareNow, VAULT.BASE_UNIT());
    }

    /// @notice Returns the total holdings of shareTokens at the time of the last extraction.
    /// @return The amount of shareTokens owned by the vault at the last extraction as a uint256
    function shareTokensOwnedByUsersAtLastExtraction() internal view returns (uint256) {
        return (VAULT.balanceOf(address(this)) - (shareTokensEarnedByAssetManager - shareTokensClaimedByAssetManager));
    }

    /// @notice Calculates the total interest earned by the Asset manager
    /// @return the total interest earned in shareTokens
    function getSHARETokensEarnedByAssetManager() internal view returns (uint256) {
        uint256 pricePerShareNow = VAULT.exchangeRate();
        if (pricePerShareAtLastExtraction == 0) return 0;
        return shareTokensEarnedByAssetManager + shareTokensToAssetManagerSinceLastExtraction(pricePerShareNow);
    }

    /// @notice Calculates the amount of shareTokens earned and not claimed by the asset manager
    /// @return The number of earned shareTokens
    function getSHARETokensUnclaimedByAssetManager() internal view returns (uint256) {
        // Sums the shareTokens earned plus additional calculated
        // earnings (since the last extraction), minus total claimed
        return getSHARETokensEarnedByAssetManager() - shareTokensClaimedByAssetManager;
    }

    /// @notice Returns the exchange rate of vshareTokens in terms of shareTokens since the last extraction.
    function vshareShareExchangeRate() public view returns (uint256) {
        // Get the total supply of shareTokens.
        uint256 vshareTokenSupply = totalSupply;

        // If there are no vshareTokens in circulation, return an exchange rate of 1:1.
        if (vshareTokenSupply == 0) return BASE_UNIT;

        // Get shareTokens currently owned by users
        uint256 shareTokensOwnedByUsers = VAULT.balanceOf(address(this)) - getSHARETokensUnclaimedByAssetManager();

        // Calculate the exchange rate by diving the total holdings by the vshareToken supply.
        return shareTokensOwnedByUsers.fdiv(vshareTokenSupply, BASE_UNIT);
    }

    /// @notice Returns the exchange rate of shareTokens to underlying
    function exchangeRate() public view returns (uint256) {
        return vshareShareExchangeRate().fmul(VAULT.exchangeRate(), BASE_UNIT);
    }

    /// @notice Returns the shareTokens owned by a user
    /// @param user The address of the user to get the shareToken balance
    /// @return The number of shareTokens owned as a uint256
    function balanceOfSHARETokens(address user) external view returns (uint256) {
        return balanceOf[user].fmul(vshareShareExchangeRate(), BASE_UNIT);
    }

    /// @notice Returns a user's Vault balance in underlying tokens.
    /// @param user The user to get the underlying balance of.
    /// @return The user's Vault balance in underlying tokens.
    function balanceOfUnderlying(address user) public view returns (uint256) {
        return balanceOf[user].fmul(exchangeRate(), BASE_UNIT);
    }

    receive() external payable {}
}

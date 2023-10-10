// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";
import {AssetManager} from "../src/AssetManager.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {SafeERC20} from "solmate/erc20/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Vault} from "vaults/Vault.sol";
import {VaultFactory} from "vaults/VaultFactory.sol";
import {MockERC20Strategy} from "vaults/test/mocks/MockERC20Strategy.sol";
import {Strategy} from "vaults/interfaces/Strategy.sol";

import {AssetManagerMockStrategy} from "./mocks/AssetManagerMockStrategy.sol";
import {AssetManager} from "../src/AssetManager.sol";

contract AssetManagerTest is Test {
    using FixedPointMathLib for uint256;

    MockERC20 public underlying;

    /// @dev Vault Logic
    Vault public vault;
    VaultFactory public vaultFactory;
    MockERC20Strategy public strategy1;
    MockERC20Strategy public strategy2;
    AssetManagerMockStrategy public cvStrategy;

    /// @dev AssetManager Logic
    AssetManager public cvault;
    address payable public caddress;
    uint256 public immutable cfeePercent = 10;
    uint256 public nonce = 1;

    /// @dev BASE_UNIT variable used in the contract
    uint256 public immutable BASE_UNIT = 10 ** 18;
}

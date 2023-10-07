// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Vault} from "vaults/Vault.sol";

contract Counter {
    uint256 public number;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }

    function increment() public {
        number++;
    }
}

// todo
// using the charities vault example, and test suite
// create an asset manager setup
// with similar flows
// test to see if working with test mocks, dont worry as much about running stategies in prod test
// can build on that later

// todo
// utilize the structure to setup a vault faster

// hackathon ending on monday, GOAL: submit the working mock

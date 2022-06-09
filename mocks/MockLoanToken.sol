// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ILoanToken} from "../idleTranchesStrategy/ITruefiPool.sol";

contract MockLoanToken is ILoanToken {
    uint256 public immutable apy;
    uint256 public immutable amount;

    constructor(uint256 _amount, uint256 _apy) {
        amount = _amount;
        apy = _apy;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20WithDecimals} from "../idleTranchesStrategy/ITruefiPool.sol";

contract MockTruefiPool {
    IERC20WithDecimals public token;
    uint256 public totalSupply;
    uint256 public poolValue;

    constructor(IERC20WithDecimals _token) {
        token = _token;
    }

    function setTotalSupply(uint256 _totalSupply) external {
        totalSupply = _totalSupply;
    }

    function setPoolValue(uint256 _poolValue) external {
        poolValue = _poolValue;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

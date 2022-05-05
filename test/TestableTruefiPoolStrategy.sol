// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {TruefiPoolStrategy} from "../idleTranchesStrategy/TruefiPoolStrategy.sol";

contract TestableTruefiPoolStrategy is TruefiPoolStrategy {
    function farm() external view returns (address) {
        return (address(_farm));
    }

    function normalize(uint256 value, uint8 decimals) external pure returns (uint256) {
        return _normalize(value, decimals);
    }

    function denormalize(uint256 value, uint8 decimals) external pure returns (uint256) {
        return _denormalize(value, decimals);
    }
}

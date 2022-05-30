// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IAllowList {
    function verify(
        uint256 index,
        bytes32 leaf,
        bytes32[] calldata proof
    ) external view returns (bool);
}

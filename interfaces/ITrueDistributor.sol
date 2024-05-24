// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITrueDistributor {
    function initialize(
        uint256 _distributionStart,
        uint256 _duration,
        uint256 _amount,
        IERC20 _asset
    ) external;

    function asset() external view returns (IERC20);

    function farm() external view returns (address);

    function distribute() external;

    function nextDistribution() external view returns (uint256);

    function empty() external;

    function setFarm(address newFarm) external;
}

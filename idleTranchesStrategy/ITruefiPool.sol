// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

interface ITruefiPool is IERC20 {
    function token() external view returns (IERC20WithDecimals);

    function join(uint256 amount) external;

    function liquidExit(uint256 amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockMultiFarm {
    IERC20 token;

    constructor(IERC20 _token) {
        token = _token;
    }

    function stake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function unstake(uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}

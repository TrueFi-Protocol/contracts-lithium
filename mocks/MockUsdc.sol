// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20WithDecimals} from "../interfaces/IERC20WithDecimals.sol";

contract MockUsdc is ERC20, IERC20WithDecimals {
    constructor() ERC20("usdc", "usdc") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function decimals() public view virtual override(IERC20WithDecimals, ERC20) returns (uint8) {
        return 6;
    }
}

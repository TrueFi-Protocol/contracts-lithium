// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20WithDecimals} from "../interfaces/IERC20WithDecimals.sol";

interface ITruefiPool is IERC20WithDecimals {
    function token() external view returns (IERC20WithDecimals);

    function join(uint256 amount) external;

    function liquidExit(uint256 amount) external;

    function poolValue() external view returns (uint256);

    function liquidValue() external view returns (uint256);

    function liquidExitPenalty(uint256 amount) external view returns (uint256);
}

interface ITrueLegacyMultiFarm {
    function rewardToken() external view returns (IERC20WithDecimals);

    function stake(IERC20 token, uint256 amount) external;

    function unstake(IERC20 token, uint256 amount) external;

    function claim(IERC20[] calldata tokens) external;

    function staked(IERC20 token, address staker) external view returns (uint256);
}

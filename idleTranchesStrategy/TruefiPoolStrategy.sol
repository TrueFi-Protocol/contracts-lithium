// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIdleCDOStrategy} from "./IIdleCDOStrategy.sol";
import {ITrueMultiFarm} from "../interfaces/ITrueMultiFarm.sol";
import {ITruefiPool, IERC20WithDecimals} from "./ITruefiPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract TruefiPoolStrategy is Initializable, OwnableUpgradeable, ERC20Upgradeable, IIdleCDOStrategy {
    using SafeERC20 for ITruefiPool;
    using SafeERC20 for IERC20WithDecimals;

    ITruefiPool private _pool;
    ITrueMultiFarm internal _farm;
    IERC20WithDecimals private _token;

    function initialize(ITruefiPool pool, ITrueMultiFarm farm) external initializer {
        _pool = pool;
        _token = pool.token();
        _farm = farm;
    }

    function token() external view returns (address) {
        return address(_token);
    }

    function strategyToken() external view returns (address) {
        return address(this);
    }

    function tokenDecimals() external view returns (uint256) {
        return _token.decimals();
    }

    function oneToken() external view returns (uint256) {
        return 10**_token.decimals();
    }

    function redeemRewards(bytes calldata _extraData) external pure returns (uint256[] memory) {
        _extraData[0];
        revert("Not implemented");
    }

    function pullStkAAVE() external pure returns (uint256) {
        return 0;
    }

    function price() external pure returns (uint256) {
        revert("Not implemented");
    }

    function getRewardTokens() external pure returns (address[] memory) {
        revert("Not implemented");
    }

    function deposit(uint256 _amount) external returns (uint256) {
        require(_amount > 0, "TruefiPoolStrategy: Deposit amount must be greater than 0");

        _token.safeTransferFrom(msg.sender, address(this), _amount);
        _token.approve(address(_pool), _amount);
        uint256 balanceBefore = _pool.balanceOf(address(this));
        _pool.join(_amount);
        uint256 balanceAfter = _pool.balanceOf(address(this));

        uint256 tfPoolTokensReceived = balanceAfter - balanceBefore;
        _mint(msg.sender, tfPoolTokensReceived);

        _pool.approve(address(_farm), tfPoolTokensReceived);
        _farm.stake(_pool, tfPoolTokensReceived);

        return tfPoolTokensReceived;
    }

    function redeem(uint256 _amount) external returns (uint256 tokensReceived) {
        _burn(msg.sender, _amount);
        _farm.unstake(_pool, _amount);

        uint256 balanceBefore = _token.balanceOf(address(this));
        _pool.liquidExit(_amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        tokensReceived = balanceAfter - balanceBefore;
        _token.safeTransfer(msg.sender, tokensReceived);
    }

    function redeemUnderlying(uint256 _amount) external pure returns (uint256) {
        _amount = 0;
        revert("Not implemented");
    }

    function getApr() external pure returns (uint256) {
        revert("Not implemented");
    }

    function _normalize(uint256 value, uint8 _decimals) internal pure returns (uint256) {
        if (_decimals == 18) {
            return value;
        }
        if (_decimals < 18) {
            return value * 10**(18 - _decimals);
        } else {
            return value / 10**(_decimals - 18);
        }
    }

    function _denormalize(uint256 value, uint8 _decimals) internal pure returns (uint256) {
        if (_decimals == 18) {
            return value;
        }
        if (_decimals < 18) {
            return value / 10**(18 - _decimals);
        } else {
            return value * 10**(_decimals - 18);
        }
    }
}

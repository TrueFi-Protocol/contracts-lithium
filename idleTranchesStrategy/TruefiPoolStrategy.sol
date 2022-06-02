// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIdleCDOStrategy} from "./IIdleCDOStrategy.sol";
import {ITruefiPool, IERC20WithDecimals, ITrueLegacyMultiFarm} from "./ITruefiPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract TruefiPoolStrategy is Initializable, OwnableUpgradeable, ERC20Upgradeable, IIdleCDOStrategy {
    using SafeERC20 for ITruefiPool;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20WithDecimals;

    uint256 private constant PRECISION = 1e30;

    ITruefiPool private _pool;
    ITrueLegacyMultiFarm internal _farm;
    IERC20WithDecimals private _token;
    IERC20WithDecimals internal _rewardToken;

    uint256 private _oneToken;
    uint8 internal _rewardTokenDecimals;
    uint8 internal _poolDecimals;

    uint256 public cumulativeRewardsPerToken;
    mapping(address => uint256) public stakerRewardsPerToken;

    function initialize(ITruefiPool pool, ITrueLegacyMultiFarm farm) external initializer {
        _pool = pool;
        _token = pool.token();
        _oneToken = 10**_token.decimals();
        _farm = farm;
        _rewardToken = farm.rewardToken();
        _rewardTokenDecimals = _rewardToken.decimals();
        _poolDecimals = _pool.decimals();
    }

    function decimals() public pure override returns (uint8) {
        return 6;
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
        return _oneToken;
    }

    function _redeemRewards() internal returns (uint256[] memory) {
        uint256 balanceBefore = _rewardToken.balanceOf(address(this));
        _farm.claim(_getTokensToClaim());
        uint256 balanceAfter = _rewardToken.balanceOf(address(this));
        uint256 claimedRewards = balanceAfter - balanceBefore;

        uint256 totalStaked = _farm.staked(_pool, address(this));

        cumulativeRewardsPerToken += _getNewCumulativeRewardsPerToken(claimedRewards, totalStaked);

        uint256 stakerRewards = _getStakerRewards();
        stakerRewardsPerToken[msg.sender] = cumulativeRewardsPerToken;
        _rewardToken.safeTransfer(msg.sender, stakerRewards);

        return _getRewardsArray(stakerRewards);
    }

    function redeemRewards(bytes calldata) external returns (uint256[] memory) {
        return _redeemRewards();
    }

    function _getNewCumulativeRewardsPerToken(uint256 claimedRewards, uint256 totalStaked) internal view returns (uint256) {
        uint256 normalizedClaimedRewards = _normalize(claimedRewards, _rewardTokenDecimals);
        uint256 normalizedTotalStaked = _normalize(totalStaked, _poolDecimals);
        return (normalizedClaimedRewards * PRECISION) / normalizedTotalStaked;
    }

    function _getStakerRewards() internal view returns (uint256) {
        uint256 cumulatedStakerRewardsPerToken = cumulativeRewardsPerToken - stakerRewardsPerToken[msg.sender];
        uint256 normalizedStakerBalance = _normalize(this.balanceOf(msg.sender), this.decimals());
        return _denormalize((cumulatedStakerRewardsPerToken * normalizedStakerBalance) / PRECISION, _rewardTokenDecimals);
    }

    function _getTokensToClaim() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(_pool);
    }

    function _getRewardsArray(uint256 rewards) internal pure returns (uint256[] memory rewardsArray) {
        rewardsArray = new uint256[](1);
        rewardsArray[0] = rewards;
    }

    function pullStkAAVE() external pure returns (uint256) {
        return 0;
    }

    function price() external view returns (uint256) {
        if (_pool.totalSupply() == 0) {
            return _oneToken;
        }
        return (_pool.poolValue() * _oneToken) / _pool.totalSupply();
    }

    function getRewardTokens() external view returns (address[] memory rewardTokens) {
        rewardTokens = new address[](1);
        rewardTokens[0] = address(_rewardToken);
    }

    function deposit(uint256 _amount) external returns (uint256 tfPoolTokensReceived) {
        require(_amount > 0, "TruefiPoolStrategy: Deposit amount must be greater than 0");

        _token.safeTransferFrom(msg.sender, address(this), _amount);
        _token.approve(address(_pool), _amount);
        uint256 tfTokensBalanceBefore = _pool.balanceOf(address(this));
        _pool.join(_amount);
        uint256 tfTokensBalanceAfter = _pool.balanceOf(address(this));

        tfPoolTokensReceived = tfTokensBalanceAfter - tfTokensBalanceBefore;
        _mint(msg.sender, tfPoolTokensReceived);

        uint256 totalStaked = _farm.staked(_pool, address(this));

        _pool.approve(address(_farm), tfPoolTokensReceived);
        uint256 rewardsBalanceBefore = _rewardToken.balanceOf(address(this));
        _farm.stake(_pool, tfPoolTokensReceived);
        uint256 rewardsBalanceAfter = _rewardToken.balanceOf(address(this));

        if (totalStaked != 0) {
            uint256 claimedRewards = rewardsBalanceAfter - rewardsBalanceBefore;
            cumulativeRewardsPerToken += _getNewCumulativeRewardsPerToken(claimedRewards, totalStaked);
            stakerRewardsPerToken[msg.sender] = cumulativeRewardsPerToken;
        }
    }

    function redeem(uint256 amount) external returns (uint256 tokensReceived) {
        require(amount > 0, "TruefiPoolStrategy: Redeem amount must be greater than 0");

        _burn(msg.sender, amount);
        _farm.unstake(_pool, amount);

        uint256 balanceBefore = _token.balanceOf(address(this));
        _pool.liquidExit(amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        tokensReceived = balanceAfter - balanceBefore;
        _token.safeTransfer(msg.sender, tokensReceived);

        _redeemRewards();
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

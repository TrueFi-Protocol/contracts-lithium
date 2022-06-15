// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIdleCDOStrategy} from "./IIdleCDOStrategy.sol";
import {ITruefiPool, IERC20WithDecimals, ITrueLegacyMultiFarm, ITrueLender, ILoanToken} from "./ITruefiPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract TruefiPoolStrategy is Initializable, OwnableUpgradeable, ERC20Upgradeable, IIdleCDOStrategy, ReentrancyGuardUpgradeable {
    using SafeERC20 for ITruefiPool;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20WithDecimals;

    uint256 private constant PRECISION = 1e30;
    uint256 private constant BASIS_POINTS = 1e4;

    ITruefiPool internal _pool;
    ITrueLegacyMultiFarm internal _farm;
    ITrueLender internal _lender;
    IERC20WithDecimals internal _token;
    IERC20WithDecimals internal _rewardToken;
    IERC20[] internal _farmTokens;
    address[] internal _rewardTokens;

    uint256 internal _oneToken;

    address public idleCDO;
    uint256 public pendingRewards;

    function initialize(ITruefiPool pool, ITrueLegacyMultiFarm farm) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        _pool = pool;
        _lender = pool.lender();
        _token = pool.token();
        _oneToken = 10**_token.decimals();
        _farm = farm;
        _rewardToken = farm.rewardToken();

        _farmTokens = toArray(IERC20(_pool));
        _rewardTokens = toArray(address(_rewardToken));

        _token.safeApprove(address(_pool), type(uint256).max);
        _pool.safeApprove(address(_farm), type(uint256).max);
    }

    modifier onlyIdleCDO() {
        require(msg.sender == idleCDO, "TruefiPoolStrategy: Caller must be Idle CDO");
        _;
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

    function setIdleCDO(address _idleCDO) external onlyOwner {
        require(_idleCDO != address(0), "TruefiPoolStrategy: Address cannot be zero");
        idleCDO = _idleCDO;
    }

    function _redeemRewards() internal returns (uint256[] memory) {
        uint256 balanceBefore = _rewardToken.balanceOf(address(this));
        _farm.claim(_farmTokens);
        uint256 balanceAfter = _rewardToken.balanceOf(address(this));
        uint256 newRewards = balanceAfter - balanceBefore;
        uint256 allRewards = newRewards + pendingRewards;

        pendingRewards = 0;
        _rewardToken.safeTransfer(msg.sender, allRewards);

        return _getRewardsArray(allRewards);
    }

    function redeemRewards(bytes calldata) external onlyIdleCDO nonReentrant returns (uint256[] memory) {
        return _redeemRewards();
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

    function getRewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function deposit(uint256 _amount) external onlyIdleCDO nonReentrant returns (uint256 tfPoolTokensReceived) {
        require(_amount > 0, "TruefiPoolStrategy: Deposit amount must be greater than 0");

        _token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 tfTokensBalanceBefore = _pool.balanceOf(address(this));
        _pool.join(_amount);
        uint256 tfTokensBalanceAfter = _pool.balanceOf(address(this));

        tfPoolTokensReceived = tfTokensBalanceAfter - tfTokensBalanceBefore;
        _mint(msg.sender, tfPoolTokensReceived);

        uint256 rewardsBalanceBefore = _rewardToken.balanceOf(address(this));
        _farm.stake(_pool, tfPoolTokensReceived);
        uint256 rewardsBalanceAfter = _rewardToken.balanceOf(address(this));

        uint256 newRewards = rewardsBalanceAfter - rewardsBalanceBefore;
        pendingRewards += newRewards;
    }

    function _redeem(uint256 amount) internal returns (uint256 tokensReceived) {
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

    function redeem(uint256 amount) external onlyIdleCDO nonReentrant returns (uint256) {
        return _redeem(amount);
    }

    function redeemUnderlying(uint256 amount) external onlyIdleCDO nonReentrant returns (uint256) {
        require(amount > 0, "TruefiPoolStrategy: Redeem amount must be greater than 0");
        int256 amountInBasisPoints = int256(amount * BASIS_POINTS);

        uint256 liquidValue = _pool.liquidValue();
        require(applyPenalty(liquidValue) >= amountInBasisPoints, "TruefiPoolStrategy: Redeem amount is too big");

        uint256 low = amount;
        uint256 high = (amount * 11) / 10; // penalty cannot be greater than 10% of amount

        if (high > liquidValue) {
            high = liquidValue;
        }

        uint256 oneTokenInBasisPoints = _oneToken * BASIS_POINTS;

        while (high > low) {
            uint256 x = (low + high) / 2;
            int256 difference = applyPenalty(x) - amountInBasisPoints;
            if (abs(difference) <= oneTokenInBasisPoints) {
                break;
            }
            if (difference > 0) {
                high = x;
            } else {
                low = x + 1;
            }
        }

        uint256 estimatedAmount = (high + low) / 2;
        uint256 estimatedTfAmount = toTfAmount(estimatedAmount);
        uint256 senderBalance = this.balanceOf(msg.sender);

        require(estimatedTfAmount <= senderBalance, "TruefiPoolStrategy: Not enough funds for penalty");
        return _redeem(estimatedTfAmount);
    }

    function applyPenalty(uint256 amount) internal view returns (int256) {
        return int256(amount * _pool.liquidExitPenalty(amount));
    }

    function toTfAmount(uint256 amount) internal view returns (uint256) {
        return (amount * _pool.totalSupply()) / _pool.poolValue();
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    // may be costly for big loans number
    function getApr() external view returns (uint256) {
        ILoanToken[] memory loans = _lender.loans(_pool);

        uint256 amountSum;
        uint256 weightedApySum;

        for (uint256 i = 0; i < loans.length; i++) {
            ILoanToken loan = loans[i];
            uint256 amount = loan.amount();
            amountSum += amount;
            weightedApySum += amount * loan.apy();
        }

        amountSum += _pool.liquidValue();
        require(amountSum > 0, "TruefiPoolStrategy: Loans value + liquid value is zero");

        return weightedApySum / amountSum;
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

    function toArray(address _address) internal pure returns (address[] memory array) {
        array = new address[](1);
        array[0] = _address;
    }

    function toArray(IERC20 _erc20) internal pure returns (IERC20[] memory array) {
        array = new IERC20[](1);
        array[0] = _erc20;
    }
}

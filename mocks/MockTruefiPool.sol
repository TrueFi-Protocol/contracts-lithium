// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IERC20WithDecimals} from "../idleTranchesStrategy/ITruefiPool.sol";
import {ABDKMath64x64} from "./Log.sol";

contract MockTruefiPool is ERC20 {
    using SafeERC20 for IERC20WithDecimals;

    uint256 private constant BASIS_PRECISION = 10000;

    uint256 private _poolValue;
    uint256 private _liquidValue;

    IERC20WithDecimals public token;
    uint256 public joiningFee;
    uint256 public claimableFees;

    mapping(address => uint256) latestJoinBlock;

    event Joined(address indexed staker, uint256 deposited, uint256 minted);
    event Exited(address indexed staker, uint256 amountToWithdraw, uint256 finalAmountToWithdraw);
    event JoiningFeeChanged(uint256 newFee);

    constructor(
        IERC20WithDecimals _poolToken,
        string memory _poolName,
        string memory _poolSymbol
    ) ERC20(_poolName, _poolSymbol) {
        token = _poolToken;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setPoolValue(uint256 __poolValue) external {
        _poolValue = __poolValue;
    }

    function poolValue() public view returns (uint256) {
        return _poolValue;
    }

    function setLiquidValue(uint256 __liquidValue) external {
        _liquidValue = __liquidValue;
    }

    function liquidValue() public view returns (uint256) {
        return _liquidValue;
    }

    function setJoiningFee(uint256 fee) external {
        require(fee <= BASIS_PRECISION, "TrueFiPool: Fee cannot exceed transaction value");
        joiningFee = fee;
        emit JoiningFeeChanged(fee);
    }

    function join(uint256 amount) external {
        uint256 fee = (amount * joiningFee) / BASIS_PRECISION;
        uint256 mintedAmount = mint(amount - fee);
        claimableFees = claimableFees + fee;

        // TODO: tx.origin will be depricated in a future ethereum upgrade
        latestJoinBlock[tx.origin] = block.number;
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit Joined(msg.sender, amount, mintedAmount);
    }

    function liquidExit(uint256 amount) external {
        require(block.number != latestJoinBlock[tx.origin], "TrueFiPool: Cannot join and exit in same block");
        require(amount <= balanceOf(msg.sender), "TrueFiPool: Insufficient funds");

        uint256 amountToWithdraw = (poolValue() * amount) / totalSupply();
        uint256 finalAmountToWithdraw = (amountToWithdraw * liquidExitPenalty(amountToWithdraw)) / BASIS_PRECISION;
        require(finalAmountToWithdraw <= liquidValue(), "TrueFiPool: Not enough liquidity in pool");

        // burn tokens sent
        _burn(msg.sender, amount);

        // ensureSufficientLiquidity(finalAmountToWithdraw); // TODO: should we keep it?

        token.safeTransfer(msg.sender, finalAmountToWithdraw);

        emit Exited(msg.sender, amountToWithdraw, finalAmountToWithdraw);
    }

    function liquidExitPenalty(uint256 amount) public view returns (uint256) {
        uint256 lv = liquidValue();
        uint256 pv = poolValue();
        if (amount == pv) {
            return BASIS_PRECISION;
        }
        uint256 liquidRatioBefore = (lv * BASIS_PRECISION) / pv;
        uint256 liquidRatioAfter = ((lv - amount) * BASIS_PRECISION) / (pv - amount);
        return BASIS_PRECISION - averageExitPenalty(liquidRatioAfter, liquidRatioBefore);
    }

    function averageExitPenalty(uint256 from, uint256 to) public pure returns (uint256) {
        require(from <= to, "TrueFiPool: To precedes from");
        if (from == BASIS_PRECISION) {
            // When all liquid, don't penalize
            return 0;
        }
        if (from == to) {
            return uint256(50000) / (from + 50);
        }
        return (integrateAtPoint(to) - integrateAtPoint(from)) / (to - from);
    }

    function integrateAtPoint(uint256 x) public pure returns (uint256) {
        return (uint256(int256(ABDKMath64x64.ln(ABDKMath64x64.fromUInt(x + 50)))) * 50000) / 2**64;
    }

    function mint(uint256 depositedAmount) internal returns (uint256) {
        if (depositedAmount == 0) {
            return depositedAmount;
        }
        uint256 mintedAmount = depositedAmount;

        // first staker mints same amount as deposited
        if (totalSupply() > 0) {
            mintedAmount = (totalSupply() * depositedAmount) / poolValue();
        }
        // mint pool liquidity tokens
        _mint(msg.sender, mintedAmount);

        return mintedAmount;
    }
}

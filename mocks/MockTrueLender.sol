// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ITruefiPool, ILoanToken, ITrueLender} from "../idleTranchesStrategy/ITruefiPool.sol";

contract MockTrueLender is ITrueLender {
    mapping(ITruefiPool => ILoanToken[]) public poolLoans;

    function value(address) external pure returns (uint256) {
        return 0;
    }

    function addLoan(ITruefiPool pool, ILoanToken loan) external {
        poolLoans[pool].push(loan);
    }

    function loans(ITruefiPool pool) public view returns (ILoanToken[] memory result) {
        result = poolLoans[pool];
    }
}

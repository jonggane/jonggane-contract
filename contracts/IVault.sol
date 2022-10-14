// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface IVault {
    function transferIn(address _token, uint256 _amount) external;

    function transferOut(address _token, uint256 _amount) external;
}

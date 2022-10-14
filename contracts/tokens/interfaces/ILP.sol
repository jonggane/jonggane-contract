// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface ILP {
    function mint(address _account, uint256 _amount) external;

    function burn(address _account, uint256 _amount) external;
}

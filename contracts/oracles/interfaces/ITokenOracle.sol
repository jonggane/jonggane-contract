// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface ITokenOracle {
    function getPrice(address _token) external view returns (uint256);

    function getPrecision(address _token) external view returns (uint256);
}

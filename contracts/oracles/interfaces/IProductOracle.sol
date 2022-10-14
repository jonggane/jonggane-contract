// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface IProductOracle {
    function getPrice(uint256 _productId) external view returns (uint256);

    function getPrecision(uint256 _productId) external view returns (uint256);
}

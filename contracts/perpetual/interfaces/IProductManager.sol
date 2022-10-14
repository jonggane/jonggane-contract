// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

interface IProductManager {
    function getDecimal(uint256 _productId) external view returns (uint256);

    function isProductAcive(uint256 _productId) external view returns (bool);

    function isInMaxLeverage(uint256 _productId, uint256 _leverage)
        external
        view
        returns (bool);

    function isInLiquidationThreshold(uint256 _productId, uint256 _leverage)
        external
        view
        returns (bool);

    function getFeeInfo(uint256 _productId)
        external
        view
        returns (uint256, uint256);
}

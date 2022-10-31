// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./interfaces/IProductManager.sol";

contract ProductManager is IProductManager {
    struct Product {
        uint256 feeRateFactor;
        uint256 decimal;
        uint256 maxLeverage;
        uint256 liquidationThreshold;
        bool isActive;
    }

    uint256 public constant FEE_PRECISION = 10**5;

    address public owner;
    Product[] public products;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only Owner");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function setFeeRateFactor(uint256 _productId, uint256 _feeRateFactor)
        external
        onlyOwner
    {
        products[_productId].feeRateFactor = _feeRateFactor;
    }

    function setMaxLeverage(uint256 _productId, uint256 _maxLeverage)
        external
        onlyOwner
    {
        products[_productId].maxLeverage = _maxLeverage;
    }

    function setLiquidationThreshold(
        uint256 _productId,
        uint256 _liquidationThreshold
    ) external onlyOwner {
        products[_productId].liquidationThreshold = _liquidationThreshold;
    }

    function setStatus(uint256 _productId, bool _isActive) external onlyOwner {
        products[_productId].isActive = _isActive;
    }

    function addProduct(
        uint256 _feeRateFactor,
        uint256 _decimal,
        uint256 _maxLeverage,
        uint256 _liquidationThreshold,
        bool _isActive
    ) public onlyOwner {
        Product memory newProduct = Product({
            feeRateFactor: _feeRateFactor,
            decimal: _decimal,
            maxLeverage: _maxLeverage,
            liquidationThreshold: _liquidationThreshold,
            isActive: _isActive
        });
        products.push(newProduct);
    }

    function getDecimal(uint256 _productId) external view returns (uint256) {
        return products[_productId].decimal;
    }

    function isProductAcive(uint256 _productId) external view returns (bool) {
        return products[_productId].isActive;
    }

    function isInMaxLeverage(uint256 _productId, uint256 _leverage)
        external
        view
        returns (bool)
    {
        return products[_productId].maxLeverage >= _leverage;
    }

    function isInLiquidationThreshold(uint256 _productId, uint256 _leverage)
        external
        view
        returns (bool)
    {
        return products[_productId].liquidationThreshold > _leverage;
    }

    function getFeeInfo(uint256 _productId)
        external
        view
        returns (uint256, uint256)
    {
        return (products[_productId].feeRateFactor, FEE_PRECISION);
    }

    function getMinimumCollateral(uint256 _productId, uint256 _notionalValue)
        external
        view
        returns (uint256)
    {
        return _notionalValue / products[_productId].maxLeverage;
    }
}

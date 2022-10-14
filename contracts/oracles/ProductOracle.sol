// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./interfaces/IProductOracle.sol";

contract ProductOracle is IProductOracle {
    address public owner;
    address public manager;

    mapping(uint256 => uint256) public prices;
    mapping(uint256 => uint256) public precisions;

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier onlyManagerOrOwner() {
        require(msg.sender == manager || msg.sender == owner);
        _;
    }

    constructor(address _owner, address _manager) {
        owner = _owner;
        manager = _manager;
    }

    function setManager(address _manager) external onlyOwner {
        manager = _manager;
    }

    function setPrice(uint256 _productId, uint256 _price)
        external
        onlyManagerOrOwner
    {
        prices[_productId] = _price;
    }

    function getPrice(uint256 _productId) external view returns (uint256) {
        return prices[_productId];
    }

    function setPrecision(uint256 _productId, uint256 _precision)
        external
        onlyManagerOrOwner
    {
        precisions[_productId] = _precision;
    }

    function getPrecision(uint256 _productId) external view returns (uint256) {
        return precisions[_productId];
    }
}

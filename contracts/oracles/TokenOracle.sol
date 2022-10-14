// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./interfaces/ITokenOracle.sol";

contract TokenOracle is ITokenOracle {
    address public owner;
    address public manager;

    mapping(address => uint256) prices;
    mapping(address => uint256) public precisions;

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

    function setPrice(address _token, uint256 _price)
        external
        onlyManagerOrOwner
    {
        prices[_token] = _price;
    }

    function getPrice(address _token) external view returns (uint256) {
        return prices[_token];
    }

    function setPrecision(address _token, uint256 _precision)
        external
        onlyManagerOrOwner
    {
        precisions[_token] = _precision;
    }

    function getPrecision(address _token) external view returns (uint256) {
        return precisions[_token];
    }
}

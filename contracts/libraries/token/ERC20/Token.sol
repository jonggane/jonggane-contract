// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./ERC20.sol";

contract Token is ERC20 {
    address public owner;
    mapping(address => uint256) public lastMintTime;

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor(address _owner) ERC20("Token", "TKN") {
        owner = _owner;
    }

    function testMint() external {
        require(
            block.timestamp - lastMintTime[msg.sender] > 1 days,
            "5000Token Per 1Day"
        );
        lastMintTime[msg.sender] = block.timestamp;
        _mint(msg.sender, 5000000000000000000000);
    }

    function mint(address _account, uint256 _amount) external onlyOwner {
        _mint(_account, _amount);
    }
}

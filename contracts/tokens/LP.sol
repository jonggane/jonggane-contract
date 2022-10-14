// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "../libraries/token/ERC20/ERC20.sol";
import "./interfaces/ILP.sol";

contract LP is ERC20, ILP {
    address public owner;

    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "MintableBaseToken: forbidden");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "MintableBaseToken: forbidden");
        _;
    }

    constructor() ERC20("LP Token", "LPT") {
        owner = msg.sender;
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    function mint(address _account, uint256 _amount) external onlyVault {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyVault {
        _burn(_account, _amount);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "./libraries/math/SafeMath.sol";
import "./libraries/token/ERC20/IERC20.sol";
import "./IVault.sol";
import "./tokens/interfaces/ILP.sol";
import "./libraries/security/ReentrancyGuard.sol";

contract Vault is ReentrancyGuard, IVault {
    using SafeMath for uint256;

    address public positionManager;

    uint256 public feeRateFactor = 10;
    uint256 public constant FEE_PRECISION = 10**3;

    mapping(address => uint256) public poolAmounts;
    mapping(address => bool) public enabledCollateral;

    address public lp;
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "Only Position Manager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only Owner");
        _;
    }

    function setCollateralEnabled(address _token) external onlyOwner {
        enabledCollateral[_token] = true;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    function initialize(address _positionManager, address _lp)
        external
        onlyOwner
    {
        positionManager = _positionManager;
        lp = _lp;
    }

    function deposit(address _token, uint256 _amount) external nonReentrant {
        require(_amount > 0, "LpManager: invalid _amount");
        require(enabledCollateral[_token], "Invalid Collateral Token");

        uint256 previousPoolAmount = poolAmounts[_token];

        IERC20(_token).transferFrom(msg.sender, address(this), _amount);

        uint256 fee = (_amount * feeRateFactor) / FEE_PRECISION;

        uint256 lpSupply = IERC20(lp).totalSupply();

        uint256 _mintAmount = previousPoolAmount == 0 || lpSupply == 0
            ? _amount - fee
            : (_amount - fee).mul(lpSupply).div(previousPoolAmount);

        ILP(lp).mint(msg.sender, _mintAmount);

        poolAmounts[_token] = previousPoolAmount.add(_amount - fee);
    }

    function withdraw(address _token, uint256 _lpAmount) external nonReentrant {
        require(enabledCollateral[_token], "Invalid Collateral Token");
        uint256 lpSupply = IERC20(lp).totalSupply();

        uint256 previousPoolAmount = poolAmounts[_token];

        uint256 _tokenAmount = previousPoolAmount.mul(_lpAmount).div(lpSupply);
        ILP(lp).burn(msg.sender, _lpAmount);

        uint256 fee = (_tokenAmount * feeRateFactor) / FEE_PRECISION;

        IERC20(_token).transfer(msg.sender, _tokenAmount - fee);

        poolAmounts[_token] = previousPoolAmount.sub(_tokenAmount - fee);
    }

    function transferIn(address _token, uint256 _amount)
        external
        onlyPositionManager
    {
        require(enabledCollateral[_token], "Invalid Collateral Token");
        uint256 nextAmount = IERC20(_token).balanceOf(address(this));
        poolAmounts[_token] = nextAmount;
    }

    function transferOut(address _token, uint256 _amount)
        external
        onlyPositionManager
    {
        require(enabledCollateral[_token], "Invalid Collateral Token");
        IERC20(_token).transfer(positionManager, _amount);
        poolAmounts[_token] = IERC20(_token).balanceOf(address(this));
    }

    function calculateTokenToLp(address _token, uint256 _tokenAmount)
        public
        view
        returns (uint256)
    {
        uint256 previousPoolAmount = poolAmounts[_token];
        uint256 fee = (_tokenAmount * feeRateFactor) / FEE_PRECISION;
        uint256 lpSupply = IERC20(lp).totalSupply();
        uint256 mintAmount = previousPoolAmount == 0 || lpSupply == 0
            ? _tokenAmount - fee
            : (_tokenAmount - fee).mul(lpSupply).div(previousPoolAmount);
        return mintAmount;
    }

    function calculateLpToToken(address _token, uint256 _lpAmount)
        public
        view
        returns (uint256)
    {
        uint256 lpSupply = IERC20(lp).totalSupply();
        uint256 previousPoolAmount = poolAmounts[_token];
        uint256 tokenAmount = previousPoolAmount.mul(_lpAmount).div(lpSupply);
        uint256 fee = (tokenAmount * feeRateFactor) / FEE_PRECISION;
        return tokenAmount - fee;
    }
}

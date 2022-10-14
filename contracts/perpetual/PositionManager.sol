// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "../libraries/token/ERC20/IERC20.sol";
import "../libraries/token/ERC20/extensions/IERC20Metadata.sol";
import "../libraries/security/ReentrancyGuard.sol";

import "../oracles/interfaces/IProductOracle.sol";
import "../oracles/interfaces/ITokenOracle.sol";
import "../IVault.sol";
import "./interfaces/IProductManager.sol";
import "./interfaces/IPositionManager.sol";

contract PositionManager is ReentrancyGuard, IPositionManager {
    struct Position {
        uint256 productId;
        uint256 notionalValue;
        uint256 size;
        uint256 collateralAmount;
        FundingFee fundingFee;
        address collateralToken;
        bool isLong;
    }

    struct FundingFee {
        uint256 cumulativeRate;
        uint256 lastTime;
    }

    uint256 public constant COMMON_DECIMAL = 18;
    uint256 public constant USD_DECIMAL = 18;
    uint256 public constant FUNDING_PRECISION = 10**10;

    bool isInitialized;
    address public owner;
    address public liquidator;

    mapping(bytes32 => Position) public positions;
    mapping(address => bool) public enabledCollateral;
    mapping(address => uint256) public reservedAmounts; //Token Amount

    mapping(address => FundingFee) public fundingFees;
    uint256 public fundingInterval;
    uint256 public fundingRateFactor;

    address public productOracle;
    address public tokenOracle;
    address public vault;
    address public productManager;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only Owner");
        _;
    }

    modifier onlyLiquidator() {
        require(msg.sender == liquidator);
        _;
    }

    function initialize(
        address _owner,
        uint256 _fundingInterval,
        uint256 _fundingRateFactor,
        address _productOracle,
        address _tokenOracle,
        address _vault,
        address _productManager
    ) external {
        require(isInitialized == false, "Already Initialized");
        owner = _owner;
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        productOracle = _productOracle;
        tokenOracle = _tokenOracle;
        vault = _vault;
        productManager = _productManager;
    }

    function setLiquidator(address _liquidator) external onlyOwner {
        liquidator = _liquidator;
    }

    function setCollateralEnabled(address _token, bool _isEnabled)
        external
        onlyOwner
    {
        enabledCollateral[_token] = _isEnabled;
    }

    function setFundingInterval(uint256 _fundingInterval) external onlyOwner {
        fundingInterval = _fundingInterval;
    }

    function setFundingRateFactor(uint256 _fundingRateFactor)
        external
        onlyOwner
    {
        fundingRateFactor = _fundingRateFactor;
    }

    function setProductOracle(address _productOracle) external onlyOwner {
        productOracle = _productOracle;
    }

    function setTokenOracle(address _tokenOracle) external onlyOwner {
        tokenOracle = _tokenOracle;
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    function setProductManager(address _productManager) external onlyOwner {
        productManager = _productManager;
    }

    function updateFundingFee(address _collateralToken) public {
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        FundingFee memory _fundingFee = fundingFees[_collateralToken];
        uint256 intervals = (block.timestamp - _fundingFee.lastTime) /
            fundingInterval;
        uint256 nextFundingRate = (fundingRateFactor *
            intervals *
            reservedAmounts[_collateralToken]) /
            IERC20(_collateralToken).balanceOf(vault);

        _fundingFee.cumulativeRate += nextFundingRate;
        _fundingFee.lastTime =
            (block.timestamp / fundingInterval) *
            fundingInterval;
        fundingFees[_collateralToken] = _fundingFee;
    }

    function increasePosition(
        uint256 _productId,
        uint256 _sizeDelta,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) external nonReentrant {
        _increasePosition(
            msg.sender,
            _productId,
            _sizeDelta,
            _isLong,
            _collateralToken,
            _collateralDelta
        );
    }

    function _increasePosition(
        address _account,
        uint256 _productId,
        uint256 _sizeDelta,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) internal {
        require(
            IProductManager(productManager).isProductAcive(_productId),
            "Invalid Product"
        );
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        updateFundingFee(_collateralToken);

        bytes32 key = getPositionKey(
            _account,
            _productId,
            _collateralToken,
            _isLong
        );

        Position memory position = positions[key];

        uint256 notionalValueDelta = productToUSD(_productId, _sizeDelta);
        uint256 fee = calculateTradeFee(_productId, notionalValueDelta);
        fee += calculateFundingFee(position);
        fee = usdToToken(fee, _collateralToken);

        position.productId = _productId;
        position.notionalValue += notionalValueDelta;
        position.size += _sizeDelta;
        position.collateralAmount += _collateralDelta;
        position.collateralAmount -= fee;
        position.collateralToken = _collateralToken;
        position.isLong = _isLong;
        position.fundingFee = fundingFees[_collateralToken];

        // Calculate temporally to get right leverage
        (uint256 profit, uint256 loss) = getPnL(position, position.size);
        (profit, loss) = (
            usdToToken(profit, _collateralToken),
            usdToToken(loss, _collateralToken)
        );
        position.collateralAmount += profit;
        position.collateralAmount -= loss;

        require(position.size > 0, "Invalid Position Size");
        require(position.collateralAmount > 0, "Invalid Collateral Amount");
        require(
            IProductManager(productManager).isInMaxLeverage(
                _productId,
                getLeverage(position)
            ),
            "Invalid Leverage"
        );

        // Recalculate after leverage validation
        position.collateralAmount -= profit;
        position.collateralAmount += loss;

        reservedAmounts[_collateralToken] += usdToToken(
            notionalValueDelta,
            _collateralToken
        );

        require(
            IERC20(_collateralToken).balanceOf(vault) >=
                reservedAmounts[_collateralToken],
            "Insufficient Vault Balance"
        );

        if (_collateralDelta > 0) {
            IERC20(_collateralToken).transferFrom(
                _account,
                address(this),
                _collateralDelta
            );
        }
        if (fee > 0) {
            IERC20(_collateralToken).transfer(vault, fee);
            IVault(vault).transferIn(_collateralToken, fee);
        }
        positions[key] = position;
    }

    function decreasePosition(
        uint256 _productId,
        uint256 _sizeDelta,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) external nonReentrant {
        _decreasePosition(
            msg.sender,
            _productId,
            _sizeDelta,
            _isLong,
            _collateralToken,
            _collateralDelta
        );
    }

    function _decreasePosition(
        address _account,
        uint256 _productId,
        uint256 _sizeDelta,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) internal {
        require(
            IProductManager(productManager).isProductAcive(_productId),
            "Invalid Product"
        );
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        updateFundingFee(_collateralToken);

        bytes32 key = getPositionKey(
            _account,
            _productId,
            _collateralToken,
            _isLong
        );
        Position memory position = positions[key];

        (uint256 profit, uint256 loss) = getPnL(position, _sizeDelta);
        (profit, loss) = (
            usdToToken(profit, _collateralToken),
            usdToToken(loss, _collateralToken)
        );
        uint256 notionalValueDelta = (position.notionalValue * _sizeDelta) /
            position.size;
        uint256 fee = calculateFundingFee(position);
        fee += calculateTradeFee(
            _productId,
            productToUSD(_productId, _sizeDelta)
        );
        fee = usdToToken(fee, _collateralToken);

        position.notionalValue -= notionalValueDelta;
        position.size -= _sizeDelta;
        position.collateralAmount -= (_collateralDelta + loss + fee);
        position.fundingFee = fundingFees[_collateralToken];

        require(
            IProductManager(productManager).isInLiquidationThreshold(
                _productId,
                getLeverage(position)
            ),
            "Invalid Leverage"
        );

        reservedAmounts[_collateralToken] -= usdToToken(
            notionalValueDelta,
            _collateralToken
        );

        if (profit > 0) {
            IVault(vault).transferOut(_collateralToken, profit);
        }
        if ((loss + fee) > 0) {
            IERC20(_collateralToken).transfer(vault, fee);
            IVault(vault).transferIn(_collateralToken, loss + fee);
        }
        if ((profit + _collateralDelta) > 0) {
            IERC20(_collateralToken).transfer(
                _account,
                profit + _collateralDelta
            );
        }
        if (position.size == 0 || position.notionalValue == 0) {
            IERC20(_collateralToken).transfer(
                _account,
                position.collateralAmount
            );
            delete positions[key];
        } else {
            positions[key] = position;
        }
    }

    function liquidatePosition(
        address _account,
        uint256 _productId,
        address _collateralToken,
        bool _isLong
    ) external onlyLiquidator nonReentrant {
        bytes32 key = getPositionKey(
            _account,
            _productId,
            _collateralToken,
            _isLong
        );
        Position memory position = positions[key];
        require(position.size > 0, "Position Manager: empty position");

        (uint256 profit, uint256 loss) = getPnL(position, position.size);
        (profit, loss) = (
            usdToToken(profit, _collateralToken),
            usdToToken(loss, _collateralToken)
        );

        uint256 fundingFee = calculateFundingFee(position);
        uint256 tradeFee = calculateTradeFee(
            _productId,
            position.notionalValue
        );
        uint256 totalFee = usdToToken(
            fundingFee + tradeFee,
            position.collateralToken
        );

        position.collateralAmount -= totalFee;
        position.collateralAmount -= loss;

        require(
            IProductManager(productManager).isInLiquidationThreshold(
                _productId,
                getLeverage(position)
            ),
            "Invalid Leverage"
        );

        IERC20(_collateralToken).transfer(vault, loss + totalFee);
        IVault(vault).transferIn(_collateralToken, loss + totalFee);

        IERC20(_collateralToken).transfer(vault, position.collateralAmount);
        IVault(vault).transferIn(_collateralToken, position.collateralAmount);

        reservedAmounts[_collateralToken] -= usdToToken(
            position.notionalValue,
            _collateralToken
        );
        delete positions[key];
    }

    function getPositionKey(
        address _account,
        uint256 _productId,
        address _collateralToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _account,
                    _productId,
                    _collateralToken,
                    _isLong
                )
            );
    }

    function convertToUSD(
        uint256 _amount,
        uint256 _decimal,
        uint256 _price,
        uint256 _precision
    ) public pure returns (uint256) {
        _amount = USD_DECIMAL > _decimal
            ? _amount * (10**abs(USD_DECIMAL, _decimal))
            : _amount / (10**abs(USD_DECIMAL, _decimal));
        return (_amount * _price) / (10**_precision);
    }

    function convertFromUSD(
        uint256 _usdAmount,
        uint256 _decimal,
        uint256 _price,
        uint256 _precision
    ) public pure returns (uint256) {
        _usdAmount = USD_DECIMAL > _decimal
            ? _usdAmount / (10**abs(USD_DECIMAL, _decimal))
            : _usdAmount * (10**abs(USD_DECIMAL, _decimal));
        return (_usdAmount * 10**_precision) / _price;
    }

    function productToUSD(uint256 _productId, uint256 _size)
        public
        view
        returns (uint256)
    {
        uint256 productDecimal = IProductManager(productManager).getDecimal(
            _productId
        );
        uint256 productPrice = IProductOracle(productOracle).getPrice(
            _productId
        );
        uint256 productPrecision = IProductOracle(productOracle).getPrecision(
            _productId
        );
        return
            convertToUSD(_size, productDecimal, productPrice, productPrecision);
    }

    function tokenToUSD(address _token, uint256 _amount)
        public
        view
        returns (uint256)
    {
        uint256 tokenDecimal = IERC20Metadata(_token).decimals();
        uint256 tokenPrice = ITokenOracle(tokenOracle).getPrice(_token);
        uint256 tokenPrecision = ITokenOracle(tokenOracle).getPrecision(_token);
        return convertToUSD(_amount, tokenDecimal, tokenPrice, tokenPrecision);
    }

    function usdToToken(uint256 _usdAmount, address _token)
        public
        view
        returns (uint256)
    {
        uint256 tokenDecimal = IERC20Metadata(_token).decimals();
        uint256 tokenPrice = ITokenOracle(tokenOracle).getPrice(_token);
        uint256 tokenPrecision = ITokenOracle(tokenOracle).getPrecision(_token);
        return
            convertFromUSD(
                _usdAmount,
                tokenDecimal,
                tokenPrice,
                tokenPrecision
            );
    }

    function usdToProduct(uint256 _usdAmount, uint256 _productId)
        public
        view
        returns (uint256)
    {
        uint256 productDecimal = IProductManager(productManager).getDecimal(
            _productId
        );
        uint256 productPrice = IProductOracle(productOracle).getPrice(
            _productId
        );
        uint256 productPrecision = IProductOracle(productOracle).getPrecision(
            _productId
        );
        return
            convertFromUSD(
                _usdAmount,
                productDecimal,
                productPrice,
                productPrecision
            );
    }

    function tokenToProduct(
        address _token,
        uint256 _amount,
        uint256 _productId
    ) public view returns (uint256) {
        return usdToProduct(tokenToUSD(_token, _amount), _productId);
    }

    function getPnL(Position memory _position, uint256 _sizeDelta)
        public
        view
        returns (uint256 profit, uint256 loss)
    {
        uint256 targetNotionalValue = (_position.notionalValue * _sizeDelta) /
            _position.size;
        uint256 currentNotionalValue = productToUSD(
            _position.productId,
            _sizeDelta
        );
        bool isValueUp = currentNotionalValue > targetNotionalValue;
        uint256 difference = abs(currentNotionalValue, targetNotionalValue);

        if (_position.isLong && isValueUp) {
            profit = difference;
        }

        if (_position.isLong && !isValueUp) {
            loss = difference;
        }

        if (!_position.isLong && isValueUp) {
            loss = difference;
        }

        if (!_position.isLong && !isValueUp) {
            profit = difference;
        }
    }

    function calculateFundingFee(Position memory _position)
        public
        view
        returns (uint256)
    {
        if (_position.notionalValue == 0) {
            return 0;
        }
        return
            (_position.notionalValue *
                (fundingFees[_position.collateralToken].cumulativeRate -
                    _position.fundingFee.cumulativeRate)) / FUNDING_PRECISION;
    }

    function calculateTradeFee(uint256 _productId, uint256 _notionalValue)
        public
        view
        returns (uint256)
    {
        (uint256 feeRateFactor, uint256 feePrecision) = IProductManager(
            productManager
        ).getFeeInfo(_productId);
        return (_notionalValue * feeRateFactor) / feePrecision;
    }

    function getLeverage(Position memory _position)
        public
        view
        returns (uint256)
    {
        if (_position.size == 0) {
            return 0;
        }
        uint256 collateralValue = tokenToUSD(
            _position.collateralToken,
            _position.collateralAmount
        );
        return
            collateralValue > 0
                ? _position.notionalValue / collateralValue
                : type(uint256).max;
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? b : a;
    }

    function abs(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}

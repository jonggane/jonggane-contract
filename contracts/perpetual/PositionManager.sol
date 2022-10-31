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
        address account;
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

    function updateFundingFee(address _collateralToken) external nonReentrant {
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );
        _updateFundingFee(_collateralToken);
    }

    function increasePosition(
        uint256 _productId,
        uint256 _sizeDelta,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) external nonReentrant {
        require(
            IProductManager(productManager).isProductAcive(_productId),
            "Invalid Product"
        );
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        FundingFee memory fundingFee = _updateFundingFee(_collateralToken);
        bytes32 positionKey = _initializePosition(
            msg.sender,
            _productId,
            _isLong,
            _collateralToken
        );
        _addCollateral(positionKey, _collateralDelta);
        _payFee(positionKey, _sizeDelta);
        _increaseSize(positionKey, _sizeDelta);
        _validatePosition(positionKey);
        _updatePositionFundingFee(positionKey, fundingFee);

        require(
            IERC20(_collateralToken).balanceOf(vault) >=
                reservedAmounts[_collateralToken],
            "Insufficient Vault Balance"
        );
    }

    function decreasePosition(
        uint256 _productId,
        uint256 _sizeDelta,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) external nonReentrant {
        require(
            IProductManager(productManager).isProductAcive(_productId),
            "Invalid Product"
        );
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        FundingFee memory fundingFee = _updateFundingFee(_collateralToken);
        bytes32 positionKey = _initializePosition(
            msg.sender,
            _productId,
            _isLong,
            _collateralToken
        );
        _settlePnl(positionKey, _sizeDelta);
        _payFee(positionKey, _sizeDelta);
        _decreaseSize(positionKey, _sizeDelta);
        _removeCollateral(positionKey, _collateralDelta);
        _validatePosition(positionKey);
        _updatePositionFundingFee(positionKey, fundingFee);
    }

    function addCollateral(
        uint256 _productId,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) external nonReentrant {
        require(
            IProductManager(productManager).isProductAcive(_productId),
            "Invalid Product"
        );
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        FundingFee memory fundingFee = _updateFundingFee(_collateralToken);
        bytes32 positionKey = _initializePosition(
            msg.sender,
            _productId,
            _isLong,
            _collateralToken
        );
        _addCollateral(positionKey, _collateralDelta);
        _payFee(positionKey, 0);
        _updatePositionFundingFee(positionKey, fundingFee);
    }

    function removeCollateral(
        uint256 _productId,
        bool _isLong,
        address _collateralToken,
        uint256 _collateralDelta
    ) external nonReentrant {
        require(
            IProductManager(productManager).isProductAcive(_productId),
            "Invalid Product"
        );
        require(
            enabledCollateral[_collateralToken],
            "Invalid Collateral Token"
        );

        FundingFee memory fundingFee = _updateFundingFee(_collateralToken);
        bytes32 positionKey = _initializePosition(
            msg.sender,
            _productId,
            _isLong,
            _collateralToken
        );
        _payFee(positionKey, 0);
        _removeCollateral(positionKey, _collateralDelta);
        _validatePosition(positionKey);
        _updatePositionFundingFee(positionKey, fundingFee);
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
                getLeverage(position, 0, 0)
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

    function _updateFundingFee(address _collateralToken)
        internal
        returns (FundingFee memory)
    {
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
        return _fundingFee;
    }

    function _initializePosition(
        address _account,
        uint256 _productId,
        bool _isLong,
        address _collateralToken
    ) internal returns (bytes32) {
        bytes32 key = getPositionKey(
            _account,
            _productId,
            _collateralToken,
            _isLong
        );
        Position memory position = positions[key];
        position.account = _account;
        position.productId = _productId;
        position.isLong = _isLong;
        position.collateralToken = _collateralToken;
        positions[key] = position;
        return key;
    }

    function _addCollateral(bytes32 positionKey, uint256 _collateralDelta)
        internal
    {
        Position memory position = positions[positionKey];
        position.collateralAmount += _collateralDelta;
        require(position.collateralAmount > 0, "Invalid Collateral Amount");

        IERC20(position.collateralToken).transferFrom(
            position.account,
            address(this),
            _collateralDelta
        );
        positions[positionKey] = position;
    }

    function _increaseSize(bytes32 positionKey, uint256 _sizeDelta) internal {
        Position memory position = positions[positionKey];
        uint256 notionalValueDelta = productToUSD(
            position.productId,
            _sizeDelta
        );

        position.notionalValue += notionalValueDelta;
        position.size += _sizeDelta;

        require(position.size > 0, "Invalid Position Size");

        reservedAmounts[position.collateralToken] += usdToToken(
            notionalValueDelta,
            position.collateralToken
        );

        positions[positionKey] = position;
    }

    function _removeCollateral(bytes32 positionKey, uint256 _collateralDelta)
        internal
    {
        Position memory position = positions[positionKey];
        if (position.size == 0) return;

        uint256 minimumCollateralAmount = usdToToken(
            IProductManager(productManager).getMinimumCollateral(
                position.productId,
                productToUSD(0, position.size)
            ),
            position.collateralToken
        );

        if (
            position.collateralAmount >=
            _collateralDelta + minimumCollateralAmount
        ) {
            position.collateralAmount -= _collateralDelta;
            IERC20(position.collateralToken).transfer(
                position.account,
                _collateralDelta
            );
            positions[positionKey] = position;
            return;
        }

        uint256 deficientTokenAmount = _collateralDelta +
            minimumCollateralAmount -
            position.collateralAmount;
        if (position.isLong) {
            position.notionalValue += tokenToUSD(
                position.collateralToken,
                deficientTokenAmount
            );
            reservedAmounts[position.collateralToken] += deficientTokenAmount;
        } else {
            position.notionalValue -= tokenToUSD(
                position.collateralToken,
                deficientTokenAmount
            );
            reservedAmounts[position.collateralToken] -= deficientTokenAmount;
        }
        position.collateralAmount = minimumCollateralAmount;

        IVault(vault).transferOut(
            position.collateralToken,
            deficientTokenAmount
        );
        IERC20(position.collateralToken).transfer(
            position.account,
            _collateralDelta
        );
        positions[positionKey] = position;
    }

    function _decreaseSize(bytes32 positionKey, uint256 _sizeDelta) internal {
        Position memory position = positions[positionKey];
        uint256 notionalValueDelta = (position.notionalValue * _sizeDelta) /
            position.size;

        position.notionalValue -= notionalValueDelta;
        position.size -= _sizeDelta;
        reservedAmounts[position.collateralToken] -= usdToToken(
            notionalValueDelta,
            position.collateralToken
        );

        if (position.size == 0 || position.notionalValue == 0) {
            IERC20(position.collateralToken).transfer(
                position.account,
                position.collateralAmount
            );
            delete positions[positionKey];
        } else {
            positions[positionKey] = position;
        }
    }

    function _settlePnl(bytes32 positionKey, uint256 _sizeDelta) internal {
        Position memory position = positions[positionKey];
        (uint256 profit, uint256 loss) = getPnL(position, _sizeDelta);
        (profit, loss) = (
            usdToToken(profit, position.collateralToken),
            usdToToken(loss, position.collateralToken)
        );

        IVault(vault).transferOut(position.collateralToken, profit);
        IERC20(position.collateralToken).transfer(position.account, profit);
        IVault(vault).transferIn(position.collateralToken, loss);
        IERC20(position.collateralToken).transfer(vault, loss);

        position.collateralAmount -= loss;
        positions[positionKey] = position;
    }

    function _updatePositionFundingFee(
        bytes32 positionKey,
        FundingFee memory _fundingFee
    ) internal {
        Position storage position = positions[positionKey];
        position.fundingFee = _fundingFee;
    }

    function _validatePosition(bytes32 positionKey) internal view {
        Position memory position = positions[positionKey];
        (uint256 profit, uint256 loss) = getPnL(position, position.size);

        require(
            IProductManager(productManager).isInMaxLeverage(
                position.productId,
                getLeverage(position, profit, loss)
            ),
            "Invalid Leverage"
        );
    }

    function _payFee(bytes32 positionKey, uint256 _sizeDelta) internal {
        Position memory position = positions[positionKey];
        uint256 fee = usdToToken(
            calculateTradeFee(
                position.productId,
                productToUSD(position.productId, _sizeDelta)
            ) + calculateFundingFee(position),
            position.collateralToken
        );

        IERC20(position.collateralToken).transfer(vault, fee);
        IVault(vault).transferIn(position.collateralToken, fee);
        position.collateralAmount -= fee;
        positions[positionKey] = position;
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
        if (_position.size == 0) {
            return (0, 0);
        }
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

    function getLeverage(
        Position memory _position,
        uint256 _profit,
        uint256 _loss
    ) public view returns (uint256) {
        if (_position.size == 0) {
            return 0;
        }

        uint256 collateralValue = tokenToUSD(
            _position.collateralToken,
            _position.collateralAmount
        );
        uint256 positiveValue = collateralValue + _profit;

        return
            positiveValue > _loss
                ? _position.notionalValue / (positiveValue - _loss)
                : type(uint256).max;
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? b : a;
    }

    function abs(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}

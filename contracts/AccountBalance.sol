// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import { AddressUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import { SafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import { SignedSafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SignedSafeMathUpgradeable.sol";
import { FullMath } from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import { ClearingHouseCallee } from "./base/ClearingHouseCallee.sol";
import { PerpSafeCast } from "./lib/PerpSafeCast.sol";
import { PerpMath } from "./lib/PerpMath.sol";
import { IExchange } from "./interface/IExchange.sol";
import { IBaseToken } from "./interface/IBaseToken.sol";
import { IIndexPrice } from "./interface/IIndexPrice.sol";
import { IOrderBook } from "./interface/IOrderBook.sol";
import { IClearingHouseConfig } from "./interface/IClearingHouseConfig.sol";
import { AccountBalanceStorageV1, Market } from "./storage/AccountBalanceStorage.sol";
import { BlockContext } from "./base/BlockContext.sol";
import { IAccountBalance } from "./interface/IAccountBalance.sol";
import { DataTypes } from "./types/DataTypes.sol";
import "hardhat/console.sol";

// never inherit any new stateful contract. never change the orders of parent stateful contracts
contract AccountBalance is IAccountBalance, BlockContext, ClearingHouseCallee, AccountBalanceStorageV1 {
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;
    using SignedSafeMathUpgradeable for int256;
    using PerpSafeCast for uint256;
    using PerpSafeCast for int256;
    using PerpMath for uint256;
    using PerpMath for int256;
    using PerpMath for uint160;
    using Market for Market.Info;

    //
    // CONSTANT
    //

    uint256 internal constant _DUST = 10 wei;
    uint256 internal constant _MIN_PARTIAL_LIQUIDATE_POSITION_VALUE = 100e18 wei; // 100 USD in decimal 18

    //
    // EXTERNAL NON-VIEW
    //

    function initialize(address clearingHouseConfigArg, address orderBookArg) external initializer {
        // IClearingHouseConfig address is not contract
        require(clearingHouseConfigArg.isContract(), "AB_CHCNC");

        // IOrderBook is not contract
        require(orderBookArg.isContract(), "AB_OBNC");

        __ClearingHouseCallee_init();

        _clearingHouseConfig = clearingHouseConfigArg;
        _orderBook = orderBookArg;
    }

    function setVault(address vaultArg) external onlyOwner {
        // vault address is not contract
        require(vaultArg.isContract(), "AB_VNC");
        _vault = vaultArg;
        emit VaultChanged(vaultArg);
    }

    /// @inheritdoc IAccountBalance
    function modifyTakerBalance(
        address trader,
        address baseToken,
        int256 base,
        int256 quote
    ) external override returns (int256, int256) {
        _requireOnlyClearingHouse();
        return _modifyTakerBalance(trader, baseToken, base, quote);
    }

    /// @inheritdoc IAccountBalance
    function modifyOwedRealizedPnl(address trader, int256 amount) external override {
        _requireOnlyClearingHouse();
        _modifyOwedRealizedPnl(trader, amount);
    }

    /// @inheritdoc IAccountBalance
    function settleQuoteToOwedRealizedPnl(address trader, address baseToken, int256 amount) external override {
        _requireOnlyClearingHouse();
        _settleQuoteToOwedRealizedPnl(trader, baseToken, amount);
    }

    /// @inheritdoc IAccountBalance
    function settleOwedRealizedPnl(address trader) external override returns (int256) {
        // only vault
        require(_msgSender() == _vault, "AB_OV");
        int256 owedRealizedPnl = _owedRealizedPnlMap[trader];
        _owedRealizedPnlMap[trader] = 0;

        return owedRealizedPnl;
    }

    /// @inheritdoc IAccountBalance
    function settleBalanceAndDeregister(
        address trader,
        address baseToken,
        int256 takerBase,
        int256 takerQuote,
        int256 realizedPnl,
        int256 makerFee
    ) external override {
        _requireOnlyClearingHouse();
        _modifyTakerBalance(trader, baseToken, takerBase, takerQuote);
        _modifyOwedRealizedPnl(trader, makerFee);

        // @audit should merge _addOwedRealizedPnl and settleQuoteToOwedRealizedPnl in some way.
        // PnlRealized will be emitted three times when removing trader's liquidity
        _settleQuoteToOwedRealizedPnl(trader, baseToken, realizedPnl);
        _deregisterBaseToken(trader, baseToken);
    }

    /// @inheritdoc IAccountBalance
    function registerBaseToken(address trader, address baseToken) external override {
        _requireOnlyClearingHouse();
        address[] storage tokensStorage = _baseTokensMap[trader];
        if (_hasBaseToken(tokensStorage, baseToken)) {
            return;
        }

        tokensStorage.push(baseToken);
        // AB_MNE: markets number exceeds
        require(tokensStorage.length <= IClearingHouseConfig(_clearingHouseConfig).getMaxMarketsPerAccount(), "AB_MNE");
    }

    /// @inheritdoc IAccountBalance
    function deregisterBaseToken(address trader, address baseToken) external override {
        _requireOnlyClearingHouse();
        _deregisterBaseToken(trader, baseToken);
    }

    /// @inheritdoc IAccountBalance
    function updateTwPremiumGrowthGlobal(
        address trader,
        address baseToken,
        int256 lastLongTwPremiumGrowthGlobalX96,
        int256 lastShortTwPremiumGrowthGlobalX96
    ) external override {
        _requireOnlyClearingHouse();
        _accountMarketMap[trader][baseToken].lastLongTwPremiumGrowthGlobalX96 = lastLongTwPremiumGrowthGlobalX96;
        _accountMarketMap[trader][baseToken].lastShortTwPremiumGrowthGlobalX96 = lastShortTwPremiumGrowthGlobalX96;
    }

    /// @inheritdoc IAccountBalance
    /// @dev we don't do swap to get position notional here.
    ///      we define the position notional in a closed market is `closed price * position size`
    function settlePositionInClosedMarket(
        address trader,
        address baseToken
    )
        external
        override
        returns (int256 positionNotional, int256 openNotional, int256 realizedPnl, uint256 closedPrice)
    {
        _requireOnlyClearingHouse();

        int256 positionSize = getTakerPositionSize(trader, baseToken);

        closedPrice = IBaseToken(baseToken).getClosedPrice();
        positionNotional = positionSize.mulDiv(closedPrice.toInt256(), 1e18);
        openNotional = _accountMarketMap[trader][baseToken].takerOpenNotional;
        realizedPnl = positionNotional.add(openNotional);

        _deleteBaseToken(trader, baseToken);
        _modifyOwedRealizedPnl(trader, realizedPnl);

        return (positionNotional, openNotional, realizedPnl, closedPrice);
    }

    //
    // EXTERNAL VIEW
    //

    /// @inheritdoc IAccountBalance
    function getClearingHouseConfig() external view override returns (address) {
        return _clearingHouseConfig;
    }

    /// @inheritdoc IAccountBalance
    function getOrderBook() external view override returns (address) {
        return _orderBook;
    }

    /// @inheritdoc IAccountBalance
    function getVault() external view override returns (address) {
        return _vault;
    }

    /// @inheritdoc IAccountBalance
    function getBaseTokens(address trader) external view override returns (address[] memory) {
        return _baseTokensMap[trader];
    }

    /// @inheritdoc IAccountBalance
    function getAccountInfo(
        address trader,
        address baseToken
    ) external view override returns (DataTypes.AccountMarketInfo memory) {
        return _accountMarketMap[trader][baseToken];
    }

    // @inheritdoc IAccountBalance
    function getTakerOpenNotional(address trader, address baseToken) external view override returns (int256) {
        return _accountMarketMap[trader][baseToken].takerOpenNotional;
    }

    // @inheritdoc IAccountBalance
    function getTotalOpenNotional(address trader, address baseToken) external view override returns (int256) {
        // // quote.pool[baseToken] + quoteBalance[baseToken]
        // (uint256 quoteInPool, ) = IOrderBook(_orderBook).getTotalTokenAmountInPoolAndPendingFee(
        //     trader,
        //     baseToken,
        //     false
        // );
        // int256 quoteBalance = getQuote(trader, baseToken);
        // return quoteInPool.toInt256().add(quoteBalance);

        return getQuote(trader, baseToken);
    }

    /// @inheritdoc IAccountBalance
    function getTotalDebtValue(address trader) external view override returns (uint256) {
        int256 totalQuoteBalance;
        int256 totalBaseDebtValue;
        uint256 tokenLen = _baseTokensMap[trader].length;
        for (uint256 i = 0; i < tokenLen; i++) {
            address baseToken = _baseTokensMap[trader][i];
            int256 baseBalance = getBase(trader, baseToken);
            int256 baseDebtValue;
            // baseDebt = baseBalance when it's negative
            if (baseBalance < 0) {
                // baseDebtValue = baseDebt * indexPrice
                baseDebtValue = baseBalance.mulDiv(_getReferencePrice(baseToken).toInt256(), 1e18);
            }
            totalBaseDebtValue = totalBaseDebtValue.add(baseDebtValue);

            // we can't calculate totalQuoteDebtValue until we have totalQuoteBalance
            totalQuoteBalance = totalQuoteBalance.add(getQuote(trader, baseToken));
        }
        int256 totalQuoteDebtValue = totalQuoteBalance >= 0 ? 0 : totalQuoteBalance;

        // both values are negative due to the above condition checks
        return totalQuoteDebtValue.add(totalBaseDebtValue).abs();
    }

    /// @inheritdoc IAccountBalance
    function getPnlAndPendingFee(address trader) external view override returns (int256, int256, uint256) {
        int256 totalPositionValue;
        uint256 tokenLen = _baseTokensMap[trader].length;
        for (uint256 i = 0; i < tokenLen; i++) {
            address baseToken = _baseTokensMap[trader][i];
            totalPositionValue = totalPositionValue.add(getTotalPositionValue(trader, baseToken));
        }
        (int256 netQuoteBalance, uint256 pendingFee) = _getNetQuoteBalanceAndPendingFee(trader);
        int256 unrealizedPnl = totalPositionValue.add(netQuoteBalance);

        return (_owedRealizedPnlMap[trader], unrealizedPnl, pendingFee);
    }

    /// @inheritdoc IAccountBalance
    function hasOrder(address trader) external view override returns (bool) {
        uint256 tokenLen = _baseTokensMap[trader].length;
        address[] memory tokens = new address[](tokenLen);

        uint256 skipped = 0;
        for (uint256 i = 0; i < tokenLen; i++) {
            address baseToken = _baseTokensMap[trader][i];
            if (!IBaseToken(baseToken).isOpen()) {
                skipped++;
                continue;
            }
            tokens[i - skipped] = baseToken;
        }

        return IOrderBook(_orderBook).hasOrder(trader, tokens);
    }

    /// @inheritdoc IAccountBalance
    function getLiquidatablePositionSize(
        address trader,
        address baseToken,
        int256 accountValue
    ) external view override returns (int256) {
        int256 marginRequirement = getMarginRequirementForLiquidation(trader);
        int256 positionSize = getTotalPositionSize(trader, baseToken);

        // No liquidatable position
        if (accountValue >= marginRequirement || positionSize == 0) {
            return 0;
        }

        // Liquidate the entire position if its value is small enough
        // to prevent tiny positions left in the system
        uint256 positionValueAbs = _getPositionValue(baseToken, positionSize).abs();
        if (positionValueAbs <= _MIN_PARTIAL_LIQUIDATE_POSITION_VALUE) {
            return positionSize;
        }

        // https://www.notion.so/perp/Backstop-LP-Spec-614b42798d4943768c2837bfe659524d#968996cadaec4c00ac60bd1da02ea8bb
        // Liquidator can only take over partial position if margin ratio is ≥ 3.125% (aka the half of mmRatio).
        // If margin ratio < 3.125%, liquidator can take over the entire position.
        //
        // threshold = mmRatio / 2 = 3.125%
        // if marginRatio >= threshold, then
        //    maxLiquidateRatio = MIN(1, 0.5 * totalAbsPositionValue / absPositionValue)
        // if marginRatio < threshold, then
        //    maxLiquidateRatio = 1
        uint24 maxLiquidateRatio = 1e6; // 100%
        if (accountValue >= marginRequirement.div(2)) {
            // maxLiquidateRatio = getTotalAbsPositionValue / ( getTotalPositionValueInMarket.abs * 2 )
            maxLiquidateRatio = FullMath
                .mulDiv(getTotalAbsPositionValue(trader), 1e6, positionValueAbs.mul(2))
                .toUint24();
            if (maxLiquidateRatio > 1e6) {
                maxLiquidateRatio = 1e6;
            }
        }

        return positionSize.mulRatio(maxLiquidateRatio);
    }

    //
    // PUBLIC VIEW
    //

    /// @inheritdoc IAccountBalance
    function getBase(address trader, address baseToken) public view override returns (int256) {
        // uint256 orderDebt = IOrderBook(_orderBook).getTotalOrderDebt(trader, baseToken, true);
        // // base = takerPositionSize - orderBaseDebt
        // return _accountMarketMap[trader][baseToken].takerPositionSize.sub(orderDebt.toInt256());
        return _accountMarketMap[trader][baseToken].takerPositionSize;
    }

    /// @inheritdoc IAccountBalance
    function getQuote(address trader, address baseToken) public view override returns (int256) {
        // uint256 orderDebt = IOrderBook(_orderBook).getTotalOrderDebt(trader, baseToken, false);
        // // quote = takerOpenNotional - orderQuoteDebt
        // return _accountMarketMap[trader][baseToken].takerOpenNotional.sub(orderDebt.toInt256());
        return _accountMarketMap[trader][baseToken].takerOpenNotional;
    }

    /// @inheritdoc IAccountBalance
    function getTakerPositionSize(address trader, address baseToken) public view override returns (int256) {
        int256 positionSize = _accountMarketMap[trader][baseToken].takerPositionSize;
        return positionSize.abs() < _DUST ? 0 : positionSize;
    }

    /// @inheritdoc IAccountBalance
    function getTotalPositionSize(address trader, address baseToken) public view override returns (int256) {
        // NOTE: when a token goes into UniswapV3 pool (addLiquidity or swap), there would be 1 wei rounding error
        // for instance, maker adds liquidity with 2 base (2000000000000000000),
        // the actual base amount in pool would be 1999999999999999999

        // makerBalance = totalTokenAmountInPool - totalOrderDebt
        // (uint256 totalBaseBalanceFromOrders, ) = IOrderBook(_orderBook).getTotalTokenAmountInPoolAndPendingFee(
        //     trader,
        //     baseToken,
        //     true
        // );
        // uint256 totalBaseDebtFromOrder = IOrderBook(_orderBook).getTotalOrderDebt(trader, baseToken, true);
        // int256 makerBaseBalance = totalBaseBalanceFromOrders.toInt256().sub(totalBaseDebtFromOrder.toInt256());

        // int256 takerPositionSize = _accountMarketMap[trader][baseToken].takerPositionSize;
        // int256 totalPositionSize = makerBaseBalance.add(takerPositionSize);
        // return totalPositionSize.abs() < _DUST ? 0 : totalPositionSize;
        int256 takerPositionSize = _accountMarketMap[trader][baseToken].takerPositionSize;
        int256 totalPositionSize = takerPositionSize;
        return totalPositionSize.abs() < _DUST ? 0 : totalPositionSize;
    }

    /// @inheritdoc IAccountBalance
    function getTotalPositionValue(address trader, address baseToken) public view override returns (int256) {
        int256 positionSize = getTotalPositionSize(trader, baseToken);
        return _getPositionValue(baseToken, positionSize);
    }

    /// @inheritdoc IAccountBalance
    function getTotalAbsPositionValue(address trader) public view override returns (uint256) {
        address[] memory tokens = _baseTokensMap[trader];
        uint256 totalPositionValue;
        uint256 tokenLen = tokens.length;
        for (uint256 i = 0; i < tokenLen; i++) {
            address baseToken = tokens[i];
            // will not use negative value in this case
            uint256 positionValue = getTotalPositionValue(trader, baseToken).abs();
            totalPositionValue = totalPositionValue.add(positionValue);
        }
        return totalPositionValue;
    }

    /// @inheritdoc IAccountBalance
    function getMarginRequirementForLiquidation(address trader) public view override returns (int256) {
        return
            getTotalAbsPositionValue(trader)
                .mulRatio(IClearingHouseConfig(_clearingHouseConfig).getMmRatio())
                .toInt256();
    }

    /// @inheritdoc IAccountBalance
    function getMarketPositionSize(address baseToken) public view override returns (uint256, uint256) {
        return (_marketMap[baseToken].longPositionSize, _marketMap[baseToken].shortPositionSize);
    }

    //
    // INTERNAL NON-VIEW
    //
    function _modifyTakerBalance(
        address trader,
        address baseToken,
        int256 base,
        int256 quote
    ) internal returns (int256, int256) {
        DataTypes.AccountMarketInfo storage accountInfo = _accountMarketMap[trader][baseToken];
        int256 oldPos = accountInfo.takerPositionSize;
        accountInfo.takerPositionSize = accountInfo.takerPositionSize.add(base);
        accountInfo.takerOpenNotional = accountInfo.takerOpenNotional.add(quote);
        if (oldPos >= 0 && base >= 0) {
            //long
            _marketMap[baseToken].longPositionSize += base.abs();
        } else if (oldPos <= 0 && base <= 0) {
            //short
            _marketMap[baseToken].shortPositionSize += base.abs();
        } else if (oldPos >= 0 && base <= 0) {
            //long => short
            if (accountInfo.takerPositionSize >= 0) {
                //new short <= old long
                _marketMap[baseToken].longPositionSize -= base.abs();
            } else {
                //new short > old long
                _marketMap[baseToken].longPositionSize -= oldPos.abs();
                _marketMap[baseToken].shortPositionSize += accountInfo.takerPositionSize.abs();
            }
        } else {
            //short => long
            if (accountInfo.takerPositionSize <= 0) {
                //new long <= old short
                _marketMap[baseToken].shortPositionSize -= base.abs();
            } else {
                //new long > old short
                _marketMap[baseToken].shortPositionSize -= oldPos.abs();
                _marketMap[baseToken].longPositionSize += accountInfo.takerPositionSize.abs();
            }
        }
        console.log("total long  %d", _marketMap[baseToken].longPositionSize);
        console.log("total short %d", _marketMap[baseToken].shortPositionSize);
        return (accountInfo.takerPositionSize, accountInfo.takerOpenNotional);
    }

    function _modifyOwedRealizedPnl(address trader, int256 amount) internal {
        if (amount != 0) {
            _owedRealizedPnlMap[trader] = _owedRealizedPnlMap[trader].add(amount);
            emit PnlRealized(trader, amount);
        }
    }

    function _settleQuoteToOwedRealizedPnl(address trader, address baseToken, int256 amount) internal {
        if (amount != 0) {
            DataTypes.AccountMarketInfo storage accountInfo = _accountMarketMap[trader][baseToken];
            accountInfo.takerOpenNotional = accountInfo.takerOpenNotional.sub(amount);
            _modifyOwedRealizedPnl(trader, amount);
        }
    }

    /// @dev this function is expensive
    function _deregisterBaseToken(address trader, address baseToken) internal {
        DataTypes.AccountMarketInfo memory info = _accountMarketMap[trader][baseToken];
        if (info.takerPositionSize.abs() >= _DUST || info.takerOpenNotional.abs() >= _DUST) {
            return;
        }

        if (IOrderBook(_orderBook).getOpenOrderIds(trader, baseToken).length > 0) {
            return;
        }

        _deleteBaseToken(trader, baseToken);
    }

    function _deleteBaseToken(address trader, address baseToken) internal {
        delete _accountMarketMap[trader][baseToken];

        address[] storage tokensStorage = _baseTokensMap[trader];
        uint256 tokenLen = tokensStorage.length;
        for (uint256 i; i < tokenLen; i++) {
            if (tokensStorage[i] == baseToken) {
                // if the target to be removed is the last one, pop it directly;
                // else, replace it with the last one and pop the last one instead
                if (i != tokenLen - 1) {
                    tokensStorage[i] = tokensStorage[tokenLen - 1];
                }
                tokensStorage.pop();
                break;
            }
        }
    }

    //
    // INTERNAL VIEW
    //

    function _getPositionValue(address baseToken, int256 positionSize) internal view returns (int256) {
        if (positionSize == 0) return 0;

        uint256 indexTwap = _getReferencePrice(baseToken);
        // both positionSize & indexTwap are in 10^18 already
        // overflow inspection:
        // only overflow when position value in USD(18 decimals) > 2^255 / 10^18
        return positionSize.mulDiv(indexTwap.toInt256(), 1e18);
    }

    function _getReferencePrice(address baseToken) internal view returns (uint256) {
        return
            IBaseToken(baseToken).isClosed()
                ? IBaseToken(baseToken).getClosedPrice()
                : IIndexPrice(baseToken).getIndexPrice(IClearingHouseConfig(_clearingHouseConfig).getTwapInterval());
    }

    /// @return netQuoteBalance = quote.balance + totalQuoteInPools
    function _getNetQuoteBalanceAndPendingFee(
        address trader
    ) internal view returns (int256 netQuoteBalance, uint256 pendingFee) {
        int256 totalTakerQuoteBalance;
        uint256 tokenLen = _baseTokensMap[trader].length;
        for (uint256 i = 0; i < tokenLen; i++) {
            address baseToken = _baseTokensMap[trader][i];
            totalTakerQuoteBalance = totalTakerQuoteBalance.add(_accountMarketMap[trader][baseToken].takerOpenNotional);
        }
        // pendingFee is included
        int256 totalMakerQuoteBalance;
        // (totalMakerQuoteBalance, pendingFee) = IOrderBook(_orderBook).getTotalQuoteBalanceAndPendingFee(
        //     trader,
        //     _baseTokensMap[trader]
        // );
        netQuoteBalance = totalTakerQuoteBalance.add(totalMakerQuoteBalance);
        return (netQuoteBalance, pendingFee);
    }

    function _hasBaseToken(address[] memory baseTokens, address baseToken) internal pure returns (bool) {
        for (uint256 i = 0; i < baseTokens.length; i++) {
            if (baseTokens[i] == baseToken) {
                return true;
            }
        }
        return false;
    }
}

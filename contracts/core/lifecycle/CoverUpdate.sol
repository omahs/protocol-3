// Neptune Mutual Protocol (https://neptunemutual.com)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "../Recoverable.sol";
import "../../dependencies/BokkyPooBahsDateTimeLibrary.sol";
import "../../libraries/CoverUtilV1.sol";
import "../../libraries/ValidationLibV1.sol";
import "../../interfaces/ICoverUpdate.sol";
import "../../interfaces/IVault.sol";
import "../../interfaces/ICxToken.sol";

/**
 * @title CoverUpdate Contract
 * @dev The cover contract enables you to delete onchain covers or products.
 *
 */
contract CoverUpdate is Recoverable, ICoverUpdate {
  using CoverUtilV1 for IStore;
  using ProtoUtilV1 for IStore;
  using StoreKeyUtil for IStore;
  using ValidationLibV1 for IStore;
  using RegistryLibV1 for IStore;

  /**
   * @dev Constructs this contract
   * @param store Enter the store
   */
  constructor(IStore store) Recoverable(store) {} // solhint-disable-line

  function _getNextMonthEndDate(uint256 date, uint256 monthsToAdd) private pure returns (uint256) {
    uint256 futureDate = BokkyPooBahsDateTimeLibrary.addMonths(date, monthsToAdd);
    return _getMonthEndDate(futureDate);
  }

  function _getMonthEndDate(uint256 date) private pure returns (uint256) {
    // Get the year and month from the date
    (uint256 year, uint256 month, ) = BokkyPooBahsDateTimeLibrary.timestampToDate(date);

    // Count the total number of days of that month and year
    uint256 daysInMonth = BokkyPooBahsDateTimeLibrary._getDaysInMonth(year, month);

    // Get the month end date
    return BokkyPooBahsDateTimeLibrary.timestampFromDateTime(year, month, daysInMonth, 23, 59, 59);
  }

  /**
   * @dev Gets future commitment of a given cover product.
   *
   * @param s Specify store instance
   * @param coverKey Enter cover key
   * @param productKey Enter product key
   * @param excludedExpiryDate Enter expiry date (from current commitment) to exclude
   *
   * @return sum The total commitment amount.
   *
   */
  function _getFutureCommitments(
    IStore s,
    bytes32 coverKey,
    bytes32 productKey,
    uint256 excludedExpiryDate
  ) private view returns (uint256 sum) {
    for (uint256 i = 0; i <= ProtoUtilV1.MAX_POLICY_DURATION; i++) {
      uint256 expiryDate = _getNextMonthEndDate(block.timestamp, i); // solhint-disable-line

      if (expiryDate == excludedExpiryDate || expiryDate <= block.timestamp) {
        // solhint-disable-previous-line
        continue;
      }

      ICxToken cxToken = ICxToken(s.getCxTokenByExpiryDateInternal(coverKey, productKey, expiryDate));

      if (address(cxToken) != address(0)) {
        sum += cxToken.totalSupply();
      }
    }
  }

  /**
   * @dev Deletes a cover
   *
   * @param s Specify store instance
   *
   */
  function _deleteCoverInternal(IStore s, bytes32 coverKey, uint256 liquidityThreshold) internal {
    s.mustBeValidCoverKey(coverKey);

    require(coverKey > 0, "Invalid cover key");

    bool supportsProducts = s.supportsProductsInternal(coverKey);
    require(supportsProducts == false, "Invalid cover");

    uint256 commitment = _getFutureCommitments(s, coverKey, bytes32(0), 0);
    require(commitment == 0, "Has active policies");

    uint256 productCount = s.countBytes32ArrayByKeys(ProtoUtilV1.NS_COVER_PRODUCT, coverKey);
    require(productCount == 0, "Has products");

    IVault vault = s.getVault(coverKey);
    uint256 balance = vault.getStablecoinBalanceOf();
    require(balance <= liquidityThreshold, "Has liquidity");

    s.deleteAddressByKeys(ProtoUtilV1.NS_COVER_OWNER, coverKey);

    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_REASSURANCE_WEIGHT, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_CREATION_FEE_EARNING, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_CREATION_DATE, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_GOVERNANCE_REPORTING_MIN_FIRST_STAKE, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_GOVERNANCE_REPORTING_PERIOD, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_RESOLUTION_COOL_DOWN_PERIOD, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_CLAIM_PERIOD, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_POLICY_RATE_FLOOR, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_POLICY_RATE_CEILING, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_REASSURANCE_RATE, coverKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_LEVERAGE_FACTOR, coverKey);

    s.setBoolByKeys(ProtoUtilV1.NS_COVER, coverKey, false);
    s.setBoolByKeys(ProtoUtilV1.NS_COVER_SUPPORTS_PRODUCTS, coverKey, false);
    s.setBoolByKeys(ProtoUtilV1.NS_COVER_REQUIRES_WHITELIST, coverKey, false);

    s.setStringByKeys(ProtoUtilV1.NS_COVER_INFO, coverKey, "");
  }

  /**
   * @dev Deletes a cover product.
   *
   */
  function _deleteProductInternal(IStore s, bytes32 coverKey, bytes32 productKey) internal {
    s.mustBeValidCoverKey(coverKey);
    s.mustSupportProducts(coverKey);
    s.mustBeValidProduct(coverKey, productKey);

    uint256 futureCommitments = _getFutureCommitments(s, coverKey, productKey, 0);
    require(futureCommitments == 0, "Has active policies");

    s.deleteBytes32ArrayByKeys(ProtoUtilV1.NS_COVER_PRODUCT, coverKey, productKey);

    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_PRODUCT, coverKey, productKey);
    s.deleteUintByKeys(ProtoUtilV1.NS_COVER_PRODUCT_EFFICIENCY, coverKey, productKey);

    s.setBoolByKeys(ProtoUtilV1.NS_COVER_PRODUCT, coverKey, productKey, false);
    s.setBoolByKeys(ProtoUtilV1.NS_COVER_REQUIRES_WHITELIST, coverKey, productKey, false);

    s.setStringByKeys(ProtoUtilV1.NS_COVER_PRODUCT, coverKey, productKey, "");
  }

  function deleteCover(bytes32 coverKey) public override nonReentrant {
    s.mustNotBePaused();
    AccessControlLibV1.mustBeCoverManager(s);

    uint256 liquidityThreshold = 10 * s.getStablecoinPrecisionInternal(); // 10 USD
    _deleteCoverInternal(s, coverKey, liquidityThreshold);

    emit CoverDeleted(coverKey);
  }

  function deleteProduct(bytes32 coverKey, bytes32 productKey) public override nonReentrant {
    s.mustNotBePaused();
    AccessControlLibV1.mustBeCoverManager(s);

    _deleteProductInternal(s, coverKey, productKey);

    emit ProductDeleted(coverKey, productKey);
  }

  /**
   * @dev Version number of this contract
   */
  function version() external pure override returns (bytes32) {
    return "v0.1";
  }

  /**
   * @dev Name of this contract
   */
  function getName() external pure override returns (bytes32) {
    return "CoverUpdate";
  }
}
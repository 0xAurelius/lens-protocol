// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.10;

import "@openzeppelin/contracts/utils/Strings.sol";

import {ICollectModule} from '../../../interfaces/ICollectModule.sol';
import {Errors} from '../../../libraries/Errors.sol';
import {FeeModuleBase} from '../FeeModuleBase.sol';
import {ModuleBase} from '../ModuleBase.sol';
import {FollowValidationModuleBase} from '../FollowValidationModuleBase.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IKlimaRetirementAggregator} from '../../../interfaces/IKlimaRetirementAggregator.sol';

/**
 * @notice A struct containing the necessary data to execute collect actions on a publication.
 *
 * @param amount The collecting cost associated with this publication.
 * @param recipient The recipient address associated with this publication.
 * @param currency The currency associated with this publication.
 * @param referralFee The referral fee associated with this publication.
 */
struct ProfilePublicationData {
    uint256 amount;
    address recipient;
    address currency;
    uint16 referralFee;
}

/**
 * @title BCTRetireCollectModule
 * @author Lens Protocol
 *
 * @notice This is a Lens CollectModule implementation, inheriting from the ICollectModule interface and
 * the FeeCollectModuleBase abstract contract.
 *
 * This module works by allowing unlimited collects for a publication at a given price.
 */
contract BCTRetireCollectModule is ICollectModule, FeeModuleBase, FollowValidationModuleBase {
    using SafeERC20 for IERC20;

    mapping(uint256 => mapping(uint256 => ProfilePublicationData))
        internal _dataByPublicationByProfile;

    address public immutable BASE_CARBON_TONNE;
    address public immutable RETIREMENT_HELPER;

    constructor(address hub, address moduleGlobals, address baseCarbonTonne, address retirementHelper) FeeModuleBase(moduleGlobals) ModuleBase(hub) {
        BASE_CARBON_TONNE = baseCarbonTonne;
        RETIREMENT_HELPER = retirementHelper;
    }

    /**
     * @notice This collect module supports the same functionality as FeeCollectModule, but swaps the fee collected to BCT and burns it. Thus, we need to decode data and execute a SushiSwap trade.
     *
     * @param profileId The token ID of the profile of the publisher, passed by the hub.
     * @param pubId The publication ID of the newly created publication, passed by the hub.
     * @param data The arbitrary data parameter, decoded into:
     *      uint256 amount: The currency total amount to levy.
     *      address currency: The currency address, must be internally whitelisted.
     *      address recipient: The custom recipient address to direct earnings to.
     *      uint16 referralFee: The referral fee to set.
     *
     * @return An abi encoded bytes parameter, which is the same as the passed data parameter.
     */
    function initializePublicationCollectModule(
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) external override onlyHub returns (bytes memory) {
        (uint256 amount, address currency, address recipient, uint16 referralFee) = abi.decode(
            data,
            (uint256, address, address, uint16)
        );
        if (
            !_currencyWhitelisted(currency) ||
            recipient == address(0) ||
            referralFee > BPS_MAX ||
            amount < BPS_MAX
        ) revert Errors.InitParamsInvalid();

        _dataByPublicationByProfile[profileId][pubId].referralFee = referralFee;
        _dataByPublicationByProfile[profileId][pubId].recipient = recipient;
        _dataByPublicationByProfile[profileId][pubId].currency = currency;
        _dataByPublicationByProfile[profileId][pubId].amount = amount;

        return data;
    }

    /**
     * @dev Processes a collect by:
     *  1. Ensuring the collector is a follower
     *  2. Charging a fee
     *  3. Swap the fee amount to BCT and retire it
     */
    function processCollect(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) external virtual override onlyHub {
        _checkFollowValidity(profileId, collector);
        if (referrerProfileId == profileId) {
            _processCollect(collector, profileId, pubId, data);
        } else {
            _processCollectWithReferral(referrerProfileId, collector, profileId, pubId, data);
        }
    }

    /**
     * @notice Returns the publication data for a given publication, or an empty struct if that publication was not
     * initialized with this module.
     *
     * @param profileId The token ID of the profile mapped to the publication to query.
     * @param pubId The publication ID of the publication to query.
     *
     * @return The ProfilePublicationData struct mapped to that publication.
     */
    function getPublicationData(uint256 profileId, uint256 pubId)
        external
        view
        returns (ProfilePublicationData memory)
    {
        return _dataByPublicationByProfile[profileId][pubId];
    }

    function _retireBCT(
        address collector,
        address beneficiary,
        uint256 pubId,
        address currency,
        uint256 amount
    ) internal {
        // Transfer amount to be retired to the retirement helper contract
        IERC20(currency).safeTransferFrom(collector, RETIREMENT_HELPER, amount);

        // Swap adjusted fee to BCT and retire
        string memory retirementMessage = string(abi.encodePacked(
            "Lens Protocol Collection Fee for Publication: ",
            Strings.toString(pubId)
        ));
        IKlimaRetirementAggregator(RETIREMENT_HELPER).retireCarbonFrom(
            beneficiary,
            currency,
            BASE_CARBON_TONNE,
            amount,
            false,
            beneficiary,
            "Lens Protocol Profile",
            retirementMessage
        );
    }

    function _processCollect(
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) internal {
        uint256 amount = _dataByPublicationByProfile[profileId][pubId].amount;
        address currency = _dataByPublicationByProfile[profileId][pubId].currency;
        _validateDataIsExpected(data, currency, amount);

        (address treasury, uint16 treasuryFee) = _treasuryData();
        address recipient = _dataByPublicationByProfile[profileId][pubId].recipient;
        uint256 treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        uint256 adjustedAmount = amount - treasuryAmount;

        _retireBCT(collector, recipient, pubId, currency, adjustedAmount); // beneficiary is recipient since they paid the fee

        // Transfer treasury amount as usual
        IERC20(currency).safeTransferFrom(collector, treasury, treasuryAmount);
    }

    function _processCollectWithReferral(
        uint256 referrerProfileId,
        address collector,
        uint256 profileId,
        uint256 pubId,
        bytes calldata data
    ) internal {
        uint256 amount = _dataByPublicationByProfile[profileId][pubId].amount;
        address currency = _dataByPublicationByProfile[profileId][pubId].currency;
        _validateDataIsExpected(data, currency, amount);

        uint256 referralFee = _dataByPublicationByProfile[profileId][pubId].referralFee;
        address treasury;
        uint256 treasuryAmount;

        // Avoids stack too deep
        {
            uint16 treasuryFee;
            (treasury, treasuryFee) = _treasuryData();
            treasuryAmount = (amount * treasuryFee) / BPS_MAX;
        }

        uint256 adjustedAmount = amount - treasuryAmount;

        if (referralFee != 0) {
            // The reason we levy the referral fee on the adjusted amount is so that referral fees
            // don't bypass the treasury fee, in essence referrals pay their fair share to the treasury.
            uint256 referralAmount = (adjustedAmount * referralFee) / BPS_MAX;
            adjustedAmount = adjustedAmount - referralAmount;

            address referralRecipient = IERC721(HUB).ownerOf(referrerProfileId);

            IERC20(currency).safeTransferFrom(collector, referralRecipient, referralAmount);
        }
        address recipient = _dataByPublicationByProfile[profileId][pubId].recipient;

        _retireBCT(collector, recipient, pubId, currency, adjustedAmount); // beneficiary is recipient since they paid the fee

        // Transfer treasury amount as usual
        IERC20(currency).safeTransferFrom(collector, treasury, treasuryAmount);
    }
}

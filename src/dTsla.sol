// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract dTsla is ConfirmedOwner, FunctionsClient, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    error dTsla__NotEnoughCollateral();
    error dTsla__DoesntMeetMinimumWithdrawalAmount();
    error dTsla__TransferFailed();

    enum MintOrRedeem {
        mint,
        redeem
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    //Math Constants
    uint256 constant PRECISION = 1e18;
    uint256 constant FEED_PRECISION = 1e10;
    uint256 constant COLLATERAL_PRECISION = 100;
    uint256 constant MIN_WITHDRAWAL_AMOUNT = 100e18; //USDC has 6 decimals

    address constant POLYGON_FUNCTIONS_ROUTER =
        0xC22a79eBA640940ABB6dF0f7982cc119578E11De;
    address constant TSLA_PRICE_FEED =
        0xc2e2848e28B9fE430Ab44F55a8437a33802a219C; //LINK -> USD for demo purposes
    address constant USDC_PRICE_FEED =
        0x1b8739bB4CdF0089d07097A9Ae5Bd274b29C6F16;
    address constant POLYGON_USDC = 0xB0A10ea7d276b75f73Ee9f3a931b2396DfB17b8D;
    uint256 constant COLLATERAL_RATIO = 200; //If $200 of TSLA in brokerage, we can mint atmost $100 worth of dTsla

    //Arguments for requestId
    bytes32 constant DON_ID =
        hex"66756e2d706f6c79676f6e2d616d6f792d310000000000000000000000000000";
    uint32 constant GAS_LIMIT = 300_000;
    uint64 immutable i_subId;

    /*------------STORAGE VARIABLES--------------*/
    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint256 private s_portfolioBalance;
    bytes32 private s_mostRecentRequestId;
    mapping(bytes32 requestId => dTslaRequest request)
        private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawlAmount)
        private s_userToWithdrawalAmount;

    uint8 donHostedSecretsSlotID = 0;
    uint64 donHostedSecretsVersion = 1715783544;

    /*------------------FUNCTIONS----------------------*/
    constructor(
        string memory mintSourceCode,
        uint64 subId,
        string memory redeemSourceCode
    )
        ConfirmedOwner(msg.sender)
        FunctionsClient(POLYGON_FUNCTIONS_ROUTER)
        ERC20("dTsla", "dTsla")
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        i_subId = subId;
    }

    /**
     * @dev Sends an HTTP request to:
     * 1. See how much TSLA is bought
     * 2. If enough TSLA in alpaca account, MINT dTsla
     * @notice This is a 2 transaction function
     */
    function sendMintRequest(
        uint256 amount
    ) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);
        req.addDONHostedSecrets(
            donHostedSecretsSlotID,
            donHostedSecretsVersion
        );
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            i_subId,
            GAS_LIMIT,
            DON_ID
        );
        s_mostRecentRequestId = requestId;
        s_requestIdToRequest[requestId] = dTslaRequest(
            amount,
            msg.sender,
            MintOrRedeem.mint
        );
        return requestId;
    }

    //Return the amount of TSLA value (in USD) stored in our brokerage
    //If we have enough TSLA token, mint the dTSLA
    function _mintFulfillRequest(
        bytes32 requestId,
        bytes memory response
    ) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId]
            .amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));

        //If TSLA collateral (how musch TSLA we've bought) > dTsla to mint -> mint
        if (
            _getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) >
            s_portfolioBalance
        ) {
            revert dTsla__NotEnoughCollateral();
        }

        if (amountOfTokensToMint != 0) {
            _mint(
                s_requestIdToRequest[requestId].requester,
                amountOfTokensToMint
            );
        }
    }

    /**
     * @notice User sends a request to sell TSLA for USDC (redemption token)
     * This will have the chainlink function call alpaca (bank) and
     * do the following:
     * 1. Sell the TSLA stock on the brokerage
     * 2. Buy USDC on the brokerage
     * 3. Send USDC to this contract for the user to withdraw
     */
    function sendRedeemRequest(uint256 amountdTsla) external {
        uint256 amountTslaInUsdc = getUsdcValueOfUsd(
            getUsdValueOfTsla(amountdTsla)
        );
        if (amountTslaInUsdc < MIN_WITHDRAWAL_AMOUNT) {
            revert dTsla__DoesntMeetMinimumWithdrawalAmount();
        }
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode);

        string[] memory args = new string[](2);
        args[0] = amountdTsla.toString();
        args[1] = amountTslaInUsdc.toString();
        req.setArgs(args);

        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            i_subId,
            GAS_LIMIT,
            DON_ID
        );
        s_requestIdToRequest[requestId] = dTslaRequest(
            amountdTsla,
            msg.sender,
            MintOrRedeem.mint
        );
        s_mostRecentRequestId = requestId;

        _burn(msg.sender, amountdTsla);
    }

    function _redeemFulfillRequest(
        bytes32 requestId,
        bytes memory response
    ) internal {
        //Assumse this has 18 decimals
        uint256 usdcAmount = uint256(bytes32(response));
        if (usdcAmount == 0) {
            uint256 amountOfdTslaBurned = s_requestIdToRequest[requestId]
                .amountOfToken;
            _mint(
                s_requestIdToRequest[requestId].requester,
                amountOfdTslaBurned
            );
            return;
        }

        //Send USDC to the user
        s_userToWithdrawalAmount[
            s_requestIdToRequest[requestId].requester
        ] += usdcAmount;
    }

    function withdraw() external {
        uint256 amountToWithdraw = s_userToWithdrawalAmount[msg.sender];
        s_userToWithdrawalAmount[msg.sender] = 0;
        bool success = ERC20(POLYGON_USDC).transfer(
            msg.sender,
            amountToWithdraw
        );
        if (!success) {
            revert dTsla__TransferFailed();
        }
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory /*err*/
    ) internal override {
        // if (s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint) {
        //     _mintFulfillRequest(requestId, response);
        // } else {
        //     _redeemFulfillRequest(requestId, response);
        // }
        s_portfolioBalance = uint256(bytes32(response));
    }

    function finishMint() external onlyOwner {
        uint256 amountOfTokensToMint = s_requestIdToRequest[
            s_mostRecentRequestId
        ].amountOfToken;
        if (
            _getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) >
            s_portfolioBalance
        ) {
            revert dTsla__NotEnoughCollateral();
        }
        _mint(
            s_requestIdToRequest[s_mostRecentRequestId].requester,
            amountOfTokensToMint
        );
    }

    function _getCollateralRatioAdjustedTotalBalance(
        uint256 amountOfTokensToMint
    ) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = getCalculatedNewTotalValue(
            amountOfTokensToMint
        );
        return
            (calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    //New expected total value in USD of all the dTsla Tokens combined
    function getCalculatedNewTotalValue(
        uint256 addedNumberOfTokens
    ) internal view returns (uint256) {
        //10 dTsls + 5 dTsla = 15 dTsla tokens * TSLA price ($100) = $1500s
        return
            ((totalSupply() /*From ERC20.sol*/ + addedNumberOfTokens) *
                getTslaPrice()) / PRECISION;
    }

    function getUsdcValueOfUsd(
        uint256 usdAmount
    ) public view returns (uint256) {
        return (usdAmount * getUsdcPrice()) / PRECISION;
    }

    function getUsdValueOfTsla(
        uint256 tslaAmount
    ) public view returns (uint256) {
        return (tslaAmount * getTslaPrice()) / PRECISION;
    }

    function getTslaPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            TSLA_PRICE_FEED
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * FEED_PRECISION;
    }

    function getUsdcPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            USDC_PRICE_FEED
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * FEED_PRECISION;
    }

    /*-------------------VIEW & PURE-----------------------*/
    function getRequest(
        bytes32 requestId
    ) external view returns (dTslaRequest memory) {
        return s_requestIdToRequest[requestId];
    }

    function getPendingWithdrawalAmount(
        address user
    ) external view returns (uint256) {
        return s_userToWithdrawalAmount[user];
    }

    function getPortfolioBalance() external view returns (uint256) {
        return s_portfolioBalance;
    }

    function getSubId() external view returns (uint64) {
        return i_subId;
    }

    function getMintSourceCode() external view returns (string memory) {
        return s_mintSourceCode;
    }

    function getRedeemSourceCode() external view returns (string memory) {
        return s_redeemSourceCode;
    }

    function getCollateralRatio() external pure returns (uint256) {
        return COLLATERAL_RATIO;
    }

    function getCollateralPrecision() external pure returns (uint256) {
        return COLLATERAL_PRECISION;
    }
}

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

    address constant SEPOLIA_FUNCTIONS_ROUTER =
        0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address constant TSLA_PRICE_FEED =
        0xc59E3633BAAC79493d908e63626716e204A45EdF; //LINK -> USD for demo purposes
    address constant USDC_PRICE_FEED =
        0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant SEPOLIA_USDC = 0x8CFFE6ad2B9A61cf13905A7Cd070FA8ad5AE799D;
    uint256 constant COLLATERAL_RATIO = 200; //If $200 of TSLA in brokerage, we can mint atmost $100 worth of dTsla

    //Arguments for requestId
    bytes32 constant DON_ID =
        hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";
    uint32 constant GAS_LIMIT = 300_000;
    uint64 immutable i_subId;

    /*------------STORAGE VARIABLES--------------*/
    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint256 private s_portfolioBalance;
    mapping(bytes32 requestId => dTslaRequest request)
        private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawlAmount)
        private s_userToWithdrawalAmount;

    /*------------------FUNCTIONS----------------------*/
    constructor(
        string memory mintSourceCode,
        uint64 subId,
        string memory redeemSourceCode
    )
        ConfirmedOwner(msg.sender)
        FunctionsClient(0xb83E47C2bC239B3bf370bc41e1459A34b41238D0)
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
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            i_subId,
            GAS_LIMIT,
            DON_ID
        );
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
        bool success = ERC20(0x8CFFE6ad2B9A61cf13905A7Cd070FA8ad5AE799D)
            .transfer(msg.sender, amountToWithdraw);
        if (!success) {
            revert dTsla__TransferFailed();
        }
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory /*err*/
    ) internal override {
        if (s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint) {
            _mintFulfillRequest(requestId, response);
        } else {
            _redeemFulfillRequest(requestId, response);
        }
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

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { Test, console } from "forge-std/Test.sol";
import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { MockMoreDebtDSC } from "../mocks/MockMoreDebtDSC.sol";
import { MockFailedMintDSC } from "../mocks/MockFailedMintDSC.sol";
import { MockFailedTransferFrom } from "../mocks/MockFailedTransferFrom.sol";
import { MockFailedTransfer } from "../mocks/MockFailedTransfer.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount);

    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;

    address public USER = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 100 ether; // $100
    uint256 public constant DEBT_TO_COVER = 100 ether; // $100
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public collateralToCover = 20 ether;
    
    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////
    // Constructor Tests //
    //////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(btcUsdPriceFeed);
        priceFeedAddresses.push(ethUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public view{
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view{
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////
    // depositCollateral Tests //
    ////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth,0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public{
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector, address(ranToken)));
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    modifier depositedCollateral(){
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral{
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

     function testRevertsIfTransferFromFails() public {
        address owner = msg.sender;

        vm.startPrank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];

        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);
        mockDsc.transferOwnership(address(mockDsce));
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
   
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////////////////
    // depositCollateral Tests //
    ////////////////////////////

    function testDepositCollateralAndMintDsc() public depositedCollateralAndMintedDsc{
        uint256 actualDepositedCollateral = engine.getCollateralDeposited(USER, weth);
        uint256 actualDscMinted = engine.getAmountDscMinted(USER);
        assertEq(AMOUNT_COLLATERAL, actualDepositedCollateral);
        assertEq(AMOUNT_DSC_TO_MINT, actualDscMinted);
    }

    ////////////////////
    // mintDsc Tests //
    //////////////////

    function testRevertsIfTryToMintZeroTokens() public depositedCollateral{
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testAmountDscMintedGetsIncreasedWhenMinting() public depositedCollateral{
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_DSC_TO_MINT);
        uint256 actualDscMinted = engine.getAmountDscMinted(USER);
        assertEq(AMOUNT_DSC_TO_MINT, actualDscMinted);
        vm.stopPrank();
    }

    function testIfDscIsActuallyMintedAndSentToTheUser() public depositedCollateral{
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_DSC_TO_MINT);
        uint256 userDscBalance = dsc.balanceOf(USER);
        uint256 actualDscMinted = engine.getAmountDscMinted(USER);
        assertEq(userDscBalance, actualDscMinted);
        vm.stopPrank();
    }

    function testIfMintFails() public {
        address owner = msg.sender;

        vm.startPrank(owner);
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];

        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.mintDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

      modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

     //////////////////////////////
    // redeem Collateral Tests  //
   //////////////////////////////
   function testRevertIfRedeemedAmountIsZero() public depositedCollateral{
    vm.startPrank(USER);
    vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    engine.redeemCollateral(weth, 0);
    vm.stopPrank();
   }

   function testIfCollateralAmountIsSubstractedFromInternalAccounting() public depositedCollateral{
    vm.startPrank(USER);
    engine.redeemCollateral(weth, 1 ether);
    uint256 remainingCollateralDeposited = engine.getCollateralDeposited(USER, weth);
    vm.stopPrank();
    assertEq(remainingCollateralDeposited, 9 ether);
   }

   function testIfCollateralRedeemedEventIsEmited() public depositedCollateral{
    vm.expectEmit(true, true, true, true, address(engine));
    emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
    vm.startPrank(USER);
    engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();
   }

   function testIfCollateralIsActuallySent() public depositedCollateral{
    uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
    vm.startPrank(USER);
    engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
    uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
    assertEq(finalWethBalance, initialWethBalance + 10 ether);
   }

   function testRedeemRevertsIfTransferFails() public{
    address owner = msg.sender;

    vm.startPrank(owner);
    MockFailedTransfer mockDsc = new MockFailedTransfer();
    tokenAddresses = [address(mockDsc)];
    priceFeedAddresses = [ethUsdPriceFeed];

    DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
    mockDsc.mint(USER, AMOUNT_COLLATERAL);
    mockDsc.transferOwnership(address(mockDsce));
    vm.stopPrank();

    vm.startPrank(USER);
    ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
    mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
    vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
    vm.stopPrank();
   }

     ///////////////////////////////////
    // redeemCollateralForDsc Tests  //
   ///////////////////////////////////
   function testRevertsIfRedeemCollateralForZeroDsc() public depositedCollateralAndMintedDsc{
    vm.startPrank(USER);
    vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    engine.redeemCollateralForDsc(weth, 0, 1 ether);
    vm.stopPrank();
   }

   function testRevertsIfANotProperCollateralizedTokenIsSentToBeRedeemed() public depositedCollateralAndMintedDsc{
    ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, 100e18);
    vm.startPrank(USER);
    vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector, address(randToken)));
    engine.redeemCollateralForDsc(address(randToken), AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
    vm.stopPrank();
   }

    ////////////////////////
    // burnDsc Tests //////
    //////////////////////

    function testRevertIfBurnAmountIsZero() public depositedCollateralAndMintedDsc{
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
    }
    function testReducesTheAmountOfDscMintedOnTheInternalAccounting() public depositedCollateralAndMintedDsc{
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.burnDsc(AMOUNT_DSC_TO_MINT);
        uint256 dscAmount = engine.getAmountDscMinted(address(USER));
        assertEq(dscAmount, 0);
    }

    function testDscIsActuallyTransferredWhenCallingBurn() public depositedCollateralAndMintedDsc{
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.burnDsc(AMOUNT_DSC_TO_MINT);
        uint256 dscAmount = dsc.balanceOf(USER);
        assertEq(dscAmount, 0);
    }

   ////////////////////////
    // healthFactor Tests //
    ////////////////////////
    function testHealthFactorReturnsRightValue() public depositedCollateralAndMintedDsc{
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(expectedHealthFactor, healthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    function testRevertIfHealthFactorIsBroken() public depositedCollateralAndMintedDsc{
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, userHealthFactor));
        engine.revertIfHealthFactorIsBroken(USER);
        vm.stopPrank();
    }

    function testIfReturnsMaxUint256WhenDscMintedAmountIsZero() public depositedCollateral{
        vm.startPrank(USER);
        uint256 healthFactor = engine.getHealthFactor(address(USER));
        assertEq(healthFactor, type(uint256).max);
    }

    ////////////////////////
    // liquidate Tests ////
    //////////////////////
    function testRevertsIfDebtToCoverIsZero() public depositedCollateralAndMintedDsc{
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.liquidate(address(weth), address(USER), 0);
        vm.stopPrank();
    }

    function testRevertIfHealthFactorIsOk() public depositedCollateral{
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(address(weth), address(USER), DEBT_TO_COVER);
        vm.stopPrank();
    }
    
    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, AMOUNT_DSC_TO_MINT);
        dsc.approve(address(engine), AMOUNT_DSC_TO_MINT);
        engine.liquidate(weth, USER, AMOUNT_DSC_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT) / engine.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_DSC_TO_MINT) / engine.getLiquidationBonus());

        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, AMOUNT_DSC_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

     ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
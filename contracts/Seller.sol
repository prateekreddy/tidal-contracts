// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Seller is ISeller, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    // For improving precision of premiumPerShare and bonusPerShare.
    uint256 constant UNIT_PER_SHARE = 1e18;

    IBonus public bonus;
    IBuyer public buyer;
    IAssetManager public assetManager;
    IERC20 public baseToken;  // By default it's USDC
    IERC20 public tidalToken;

    struct WithdrawRequest {
        uint8 category;
        uint256 amount;
        uint256 time;
        bool executed;
    }

    // who => WithdrawRequest[]
    mapping(address => WithdrawRequest[]) public withdrawRequestMap;

    mapping(address => mapping(uint256 => bool)) public currentBasket;
    mapping(address => mapping(uint256 => bool)) public futureBasket;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 premiumPerShare;
        uint256 bonusPerShare;
    }

    mapping(uint8 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 week;
        uint256 currentBalance;
        uint256 futureBalance;
        uint256 premium;
        uint256 bonus;
    }

    mapping(address => mapping(uint8 => UserInfo)) public userInfo;

    // By category.
    mapping(uint8 => uint256) public categoryBalance;

    // assetIndex => amount
    mapping(uint256 => uint256) public override assetBalance;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // payoutId => PayoutInfo
    mapping(uint256 => PayoutInfo) public payoutInfo;

    // assetIndex => payoutId
    mapping(uint256 => uint256) public payoutIdMap;

    // who => assetIndex => payoutId
    mapping(address => mapping(uint256 => uint256)) userPayoutIdMap;

    constructor () public { }

    function setBaseToken(IERC20 baseToken_) external onlyOwner {
        baseToken = baseToken_;
    }

    function setTidalToken(IERC20 tidalToken_) external onlyOwner {
        tidalToken = tidalToken_;
    }

    function setAssetManager(IAssetManager assetManager_) external onlyOwner {
        assetManager = assetManager_;
    }

    function setBuyer(IBuyer buyer_) external onlyOwner {
        buyer = buyer_;
    }

    function setBonus(IBonus bonus_) external onlyOwner {
        bonus = bonus_;
    }

    function getWeekByTime(uint256 time_) public pure returns(uint256) {
        return time_ / (7 days);
    }

    function getWithdrawTime(uint256 time_) public pure returns(uint256) {
        return (time_ / (7 days) + 2) * (7 days);
    }

    // Update and pay last week's premium.
    function updatePremium(uint8 category_) external {
        uint256 week = getWeekByTime(now);
        require(buyer.weekToUpdate() == week, "buyer not ready");
        require(poolInfo[category_].weekOfPremium < week, "already updated");

        uint256 amount = buyer.premiumForSeller(category_);

        if (categoryBalance[category_] > 0) {
            IERC20(baseToken).safeTransferFrom(address(buyer), address(this), amount);
            poolInfo[category_].premiumPerShare =
                amount.mul(UNIT_PER_SHARE).div(categoryBalance[category_]);
        }

        poolInfo[category_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint8 category_, uint256 amount_) external override {
        require(msg.sender == address(bonus), "Only Bonus can call");

        uint256 week = getWeekByTime(now);

        require(poolInfo[category_].weekOfBonus < week, "already updated");

        if (categoryBalance[category_] > 0) {
            IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo[category_].bonusPerShare =
                amount_.mul(UNIT_PER_SHARE).div(categoryBalance[category_]);
        }

        poolInfo[category_].weekOfBonus = week;
    }

    function isAssetLocked(address who_, uint8 category_) public view returns(bool) {
        for (uint256 i = 0; i < assetManager.getIndexesByCategoryLength(category_); ++i) {
            uint256 index = assetManager.getIndexesByCategory(category_, i);
            uint256 payoutId = payoutIdMap[index];

            if (payoutId > 0 && !payoutInfo[payoutId].finished &&
                currentBasket[who_][index] && userPayoutIdMap[who_][index] < payoutId) return true;
        }

        return false;
    }

    function hasPendingPayout(uint256[] memory basketIndexes_) public view returns(bool) {
        for (uint256 i = 0; i < basketIndexes_.length; ++i) {
            uint256 assetIndex = basketIndexes_[i];
            uint256 payoutId = payoutIdMap[assetIndex];
            if (payoutId > 0 && !payoutInfo[payoutId].finished) return true;
        }

        return false;
    }

    function hasIndex(uint256[] memory basketIndexes_, uint256 index_) public pure returns(bool) {
        for (uint256 i = 0; i < basketIndexes_.length; ++i) {
            if (basketIndexes_[i] == index_) return true;
        }

        return false;
    }

    function changeBasket(uint8 category_, uint256[] calldata basketIndexes_) external {
        require(!isAssetLocked(msg.sender, category_), "Asset locked");
        require(!hasPendingPayout(basketIndexes_), "Has pending payout");

        uint256 i;

        for (i = 0; i < assetManager.getIndexesByCategoryLength(category_); ++i) {
            uint256 index = assetManager.getIndexesByCategory(category_, i);
            futureBasket[msg.sender][index] = false;
        }

        for (i = 0; i < basketIndexes_.length; ++i) {
            futureBasket[msg.sender][basketIndexes_[i]] = true;
        }
    }

    // Called for every user every week for every category.
    function update(address who_, uint8 category_) public {
        // Update user's last week's premium and bonus.
        uint256 week = getWeekByTime(now);

        // Return if premium or bonus not updated, or user already updated.
        if (poolInfo[category_].weekOfPremium < week ||
                poolInfo[category_].weekOfBonus < week ||
                userInfo[who_][category_].week >= week) {
            return;
        }

        uint256 currentBalance = userInfo[who_][category_].currentBalance;
        uint256 futureBalance = userInfo[who_][category_].futureBalance;

        // Update premium.
        userInfo[who_][category_].premium = userInfo[who_][category_].premium.add(currentBalance.mul(
            poolInfo[category_].premiumPerShare).div(UNIT_PER_SHARE));

        // Update bonus.
        userInfo[who_][category_].bonus = userInfo[who_][category_].bonus.add(currentBalance.mul(
            poolInfo[category_].bonusPerShare).div(UNIT_PER_SHARE));

        // Update balances and baskets if no claims.
        if (!isAssetLocked(who_, category_)) {
            for (uint256 i = 0; i < assetManager.getIndexesByCategoryLength(category_); ++i) {
                uint256 index = assetManager.getIndexesByCategory(category_, i);

                assetBalance[index] = assetBalance[index].add(
                    futureBasket[who_][index] ? futureBalance : 0).sub(
                    currentBasket[who_][index] ? currentBalance : 0);

                currentBasket[who_][index] = futureBasket[who_][index];
            }

            categoryBalance[category_] = categoryBalance[category_].add(
                futureBalance).sub(currentBalance);

            userInfo[who_][category_].currentBalance = futureBalance;
        }

        // Update week.
        userInfo[who_][category_].week = week;
    }

    function deposit(uint8 category_, uint256 amount_) external {
        require(!isAssetLocked(msg.sender, category_), "Asset locked");
        require(userInfo[msg.sender][category_].week == getWeekByTime(now), "Not updated yet");

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount_);

        userInfo[msg.sender][category_].futureBalance = userInfo[msg.sender][category_].futureBalance.add(amount_);
    }

    function withdraw(uint8 category_, uint256 amount_) external {
        require(!isAssetLocked(msg.sender, category_), "Asset locked");

        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userInfo[msg.sender][category_].currentBalance, "Not enough user balance");

        WithdrawRequest memory request;
        request.category = category_;
        request.amount = amount_;
        request.time = now;
        request.executed = false;
        withdrawRequestMap[msg.sender].push(request);
    }

    function withdrawReady(address who_, uint256 requestIndex_) external {
        WithdrawRequest storage request = withdrawRequestMap[who_][requestIndex_];

        require(!isAssetLocked(who_, request.category), "Asset locked");
        require(userInfo[who_][request.category].week == getWeekByTime(now), "Not updated yet");
        require(!request.executed, "already executed");

        uint256 unlockTime = getWithdrawTime(request.time);
        require(now > unlockTime, "Not ready to withdraw yet");

        IERC20(baseToken).safeTransfer(who_, request.amount);

        for (uint256 i = 0; i < assetManager.getIndexesByCategoryLength(request.category); ++i) {
            uint256 index = assetManager.getIndexesByCategory(request.category, i);

            // Only process assets in my basket.
            if (currentBasket[who_][index]) {
                assetBalance[index] = assetBalance[index].sub(request.amount);
            }
        }

        userInfo[who_][request.category].currentBalance = userInfo[who_][request.category].currentBalance.sub(request.amount);
        userInfo[who_][request.category].futureBalance = userInfo[who_][request.category].futureBalance.sub(request.amount);
        categoryBalance[request.category] = categoryBalance[request.category].sub(request.amount);
 
        request.executed = true;
    }

    function claimPremium(uint8 category_) external {
        IERC20(baseToken).safeTransfer(msg.sender, userInfo[msg.sender][category_].premium);
        userInfo[msg.sender][category_].premium = 0;
    }

    function claimBonus(uint8 category_) external {
        IERC20(tidalToken).safeTransfer(msg.sender, userInfo[msg.sender][category_].bonus);
        userInfo[msg.sender][category_].bonus = 0;
    }

    function startPayout(uint256 assetIndex_, uint256 payoutId_) external onlyOwner {
        require(payoutId_ == payoutIdMap[assetIndex_] + 1, "payoutId should be increasing");
        payoutIdMap[assetIndex_] = payoutId_;
    }

    function setPayout(uint256 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external onlyOwner {
        require(payoutId_ == payoutIdMap[assetIndex_], "payoutId should be started");
        require(payoutInfo[payoutId_].total == 0, "already set");
        require(total_ <= assetBalance[assetIndex_], "More than asset");

        payoutInfo[payoutId_].toAddress = toAddress_;
        payoutInfo[payoutId_].total = total_;
        payoutInfo[payoutId_].unitPerShare = total_.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]);
        payoutInfo[payoutId_].paid = 0;
        payoutInfo[payoutId_].finished = false;
    }

    function doPayout(address who_, uint256 assetIndex_) external {
        require(currentBasket[who_][assetIndex_], "must be in basket");

        for (uint256 payoutId = userPayoutIdMap[who_][assetIndex_] + 1; payoutId <= payoutIdMap[assetIndex_]; ++payoutId) {
            userPayoutIdMap[who_][assetIndex_] = payoutId;

            if (payoutInfo[payoutId].finished) {
                continue;
            }

            uint8 category = assetManager.getAssetCategory(assetIndex_);
            uint256 amountToPay = userInfo[who_][category].currentBalance.mul(payoutInfo[payoutId].unitPerShare).div(UNIT_PER_SHARE);

            userInfo[who_][category].currentBalance = userInfo[who_][category].currentBalance.sub(amountToPay);
            userInfo[who_][category].futureBalance = userInfo[who_][category].futureBalance.sub(amountToPay);
            categoryBalance[category] = categoryBalance[category].sub(amountToPay);
            assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(amountToPay);
            payoutInfo[payoutId].paid = payoutInfo[payoutId].paid.add(amountToPay);
        }
    }

    function finishPayout(uint256 payoutId_) external {
        require(!payoutInfo[payoutId_].finished, "already finished");

        if (payoutInfo[payoutId_].paid < payoutInfo[payoutId_].total) {
            // In case there is still small error.
            IERC20(baseToken).safeTransferFrom(msg.sender, address(this), payoutInfo[payoutId_].total - payoutInfo[payoutId_].paid);
            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].total;
        }

        IERC20(baseToken).safeTransfer(payoutInfo[payoutId_].toAddress, payoutInfo[payoutId_].total);

        payoutInfo[payoutId_].finished = true;
    }
}

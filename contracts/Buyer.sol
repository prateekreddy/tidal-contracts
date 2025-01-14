// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The base of percentage.
    uint256 constant PERCENTAGE_BASE = 100;

    // The base of utilization.
    uint256 constant UTILIZATION_BASE = 1e6;

    // The base of premium rate and accWeeklyCost
    uint256 constant PREMIUM_BASE = 1e6;

    // For improving precision of bonusPerShare.
    uint256 constant UNIT_PER_SHARE = 1e18;

    IERC20 public baseToken;  // By default it's USDC
    IERC20 public tidalToken;

    IAssetManager public assetManager;
    IBonus public bonus;
    IGuarantor public guarantor;
    ISeller public seller;
    uint256 public guarantorPercentage = 10;  // 10%

    struct PoolInfo {
        uint256 weekOfBonus;
        uint256 bonusPerShare;
    }

    // assetIndex => PoolInfo
    mapping(uint256 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 balance;
        uint256 weekBegin;  // The week the coverage begin
        uint256 weekEnd;  // The week the coverage end
        uint256 weekUpdated;  // The week that balance was updated
        uint256 bonus;
    }

    mapping(address => UserInfo) public userInfoMap;

    // user => assetIndex => amount
    mapping(address => mapping(uint256 => uint256)) public override currentSubscription;

    // user => assetIndex => amount
    mapping(address => mapping(uint256 => uint256)) public override futureSubscription;

    // assetIndex => total
    mapping(uint256 => uint256) public assetSubscription;

    // assetIndex => utilization
    mapping(uint256 => uint256) public assetUtilization;

    // assetIndex => total
    mapping(uint256 => uint256) public override premiumForGuarantor;

    // category => total
    mapping(uint8 => uint256) public override premiumForSeller;

    uint256 public override weekToUpdate;

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

    function setBonus(IBonus bonus_) external onlyOwner {
        bonus = bonus_;
    }

    function setSeller(ISeller seller_) external onlyOwner {
        seller = seller_;
    }

    function setGuarantor(IGuarantor guarantor_) external onlyOwner {
        guarantor = guarantor_;
    }

    function setGuarantorPercentage(uint256 percentage_) external onlyOwner {
        require(percentage_ < PERCENTAGE_BASE, "Invalid input");
        guarantorPercentage = percentage_;
    }

    function getPremiumRate(uint256 assetIndex_) public view returns(uint256) {
        uint8 category = assetManager.getAssetCategory(assetIndex_);
        uint256 extra;
        uint256 cap = UTILIZATION_BASE * 8 / 10;  // 80%

        if (assetUtilization[assetIndex_] >= cap) {
            extra = 30000;
        } else {
            extra = 30000 * assetUtilization[assetIndex_] / cap;
        }

        if (category == 0) {
            return 14000 + extra;
        } else if (category == 1) {
            return 56000 + extra;
        } else {
            return 108000 + extra;
        }
    }

    function getCurrentWeek() public view returns(uint256) {
        return now.div(7 days);
    }

    function isUserCovered(address who_) public override view returns(bool) {
        return userInfoMap[who_].weekEnd == getCurrentWeek();
    }

    function getTotalFuturePremium(address who_) public view returns(uint256) {
        uint256 total = 0;
        for (uint256 index = 0; index < assetManager.getAssetLength(); ++index) {
            if (futureSubscription[who_][index] > 0) {
                total = total.add(futureSubscription[who_][index].mul(getPremiumRate(index)).div(PREMIUM_BASE));
            }
        }

        return total;
    }

    function getBalance(address who_) public view returns(uint256) {
        return userInfoMap[who_].balance;
    }

    function getUtilization(uint256 assetIndex_) public view returns(uint256) {
        uint256 sellerAssetBalance = seller.assetBalance(assetIndex_);

        if (sellerAssetBalance == 0) {
            return 0;
        }

        if (assetSubscription[assetIndex_] > sellerAssetBalance) {
            return UTILIZATION_BASE;
        }

        return assetSubscription[assetIndex_] * UTILIZATION_BASE / sellerAssetBalance;
    }

    // Called every week.
    function beforeUpdate() public {
        uint256 currentWeek = getCurrentWeek();

        require(weekToUpdate < currentWeek, "Already called");

        if (weekToUpdate > 0) {
            uint8 category;

            for (category = 0; category < assetManager.getCategoryLength(); ++category) {
                premiumForSeller[category] = 0;
            }

            uint256 totalForGuarantor = 0;
            uint256 totalForSeller = 0;

            // To preserve last week's data before update buyers.
            for (uint256 index = 0; index < assetManager.getAssetLength(); ++index) {
                category = assetManager.getAssetCategory(index);
                uint256 premiumOfAsset = assetSubscription[index] * 
                    getPremiumRate(index) / PREMIUM_BASE;

                premiumForGuarantor[index] = premiumOfAsset * guarantorPercentage / PERCENTAGE_BASE;
                totalForGuarantor = totalForGuarantor.add(premiumForGuarantor[index]);

                uint256 deltaForCategory = premiumOfAsset * (PERCENTAGE_BASE - guarantorPercentage) / PERCENTAGE_BASE;
                premiumForSeller[category] = premiumForSeller[category].add(deltaForCategory);
                totalForSeller = totalForSeller.add(deltaForCategory);

                // Calculate assetUtilization from assetSubscription and seller.assetBalance
                assetUtilization[index] = getUtilization(index);
            }

            IERC20(baseToken).approve(address(guarantor), totalForGuarantor);
            IERC20(baseToken).approve(address(seller), totalForSeller);
        }

        weekToUpdate = currentWeek;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint256 assetIndex_, uint256 amount_) external override {
        require(msg.sender == address(bonus), "Only Bonus can call");

        uint256 currentWeek = getCurrentWeek();

        require(currentWeek == weekToUpdate, "Not ready to update");
        require(poolInfo[assetIndex_].weekOfBonus < currentWeek, "already updated");

        if (assetSubscription[assetIndex_] > 0) {
            IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo[assetIndex_].bonusPerShare = amount_.mul(UNIT_PER_SHARE).div(assetSubscription[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfBonus = currentWeek;

        // HACK: Now reset, because it's useless and we will re-sum it later.
        assetSubscription[assetIndex_] = 0;
    }

    // Called for every user every week.
    function update(address who_) public {
        uint256 currentWeek = getCurrentWeek();

        require(currentWeek == weekToUpdate, "Not ready to update");
        require(userInfoMap[who_].weekUpdated < currentWeek, "Already updated");

        uint256 index;

        // Check bonus.
        for (index = 0; index < assetManager.getAssetLength(); ++index) {
            require(poolInfo[index].weekOfBonus == currentWeek, "Not ready");
        }

        // Get per user premium
        uint256 cost = getTotalFuturePremium(who_);

        if (userInfoMap[who_].balance >= cost) {
            userInfoMap[who_].balance = userInfoMap[who_].balance.sub(cost);

            // Update user bonus.
            userInfoMap[who_].bonus = userInfoMap[who_].bonus.add(currentSubscription[who_][index].mul(
                poolInfo[index].bonusPerShare).div(UNIT_PER_SHARE));

            if (userInfoMap[who_].weekBegin == 0 ||
                    userInfoMap[who_].weekEnd < userInfoMap[who_].weekUpdated) {
                userInfoMap[who_].weekBegin = currentWeek;
            }

            userInfoMap[who_].weekEnd = currentWeek;

            for (index = 0; index < assetManager.getAssetLength(); ++index) {
                if (futureSubscription[who_][index] > 0) {
                    currentSubscription[who_][index] = futureSubscription[who_][index];

                    // Update per asset premium
                    assetSubscription[index] = assetSubscription[index].add(
                            futureSubscription[who_][index]);
                } else if (currentSubscription[who_][index] > 0) {
                    currentSubscription[who_][index] = 0;
                }
            }
        }

        userInfoMap[who_].weekUpdated = currentWeek;  // This week.
    }

    // Deposit
    function deposit(uint256 amount_) external {
        update(msg.sender);

        baseToken.safeTransferFrom(msg.sender, address(this), amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.add(amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external {
        update(msg.sender);

        require(userInfoMap[msg.sender].balance > amount_, "not enough balance");
        baseToken.safeTransfer(msg.sender, amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.sub(amount_);
    }

    function subscribe(uint256 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].add(amount_);
    }

    function unsubscribe(uint256 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].sub(amount_);
    }

    function claimBonus() external {
        IERC20(tidalToken).safeTransfer(msg.sender, userInfoMap[msg.sender].bonus);
        userInfoMap[msg.sender].bonus = 0;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IBuyer {
    function premiumForGuarantor(uint256 assetIndex_) external view returns(uint256);
    function premiumForSeller(uint8 category_) external view returns(uint256);
    function weekToUpdate() external view returns(uint256);
    function currentSubscription(address who_, uint256 assetIndex_) external view returns(uint256);
    function futureSubscription(address who_, uint256 assetIndex_) external view returns(uint256);
    function isUserCovered(address who_) external view returns(bool);
    function updateBonus(uint256 assetIndex_, uint256 amount_) external;
}

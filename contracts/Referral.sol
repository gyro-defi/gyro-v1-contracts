pragma solidity ^0.7.5;

import "./libs/Ownable.sol";
import "./libs/SafeMath.sol";
import "./libs/SafeERC20.sol";
import "./libs/IERC2612Permit.sol";

contract Referral is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public rewardToken;
    address public treasury;
    uint256 public fee; // in Gyro
    uint256 public referrerShare; // out of 10000, 500 is 5%
    uint256 public depositorShare; // out of 10000, 500 is 5%

    mapping(bytes32 => address) public referrals;
    mapping(bytes32 => uint256) public rewards;

    event LogNewReferral(address indexed account, bytes32 indexed code);
    event LogClaim(address indexed recipient, uint256 amount);
    event LogDepositRewards(address indexed sender, address indexed recipient, uint256 amount);

    constructor(
        address rewardToken_,
        address treasury_,
        uint256 fee_,
        uint256 referrerShare_,
        uint256 depositorShare_
    ) {
        require(rewardToken_ != address(0));
        rewardToken = rewardToken_;
        require(treasury_ != address(0));
        treasury = treasury_;

        fee = fee_;
        referrerShare = referrerShare_;
        depositorShare = depositorShare_;
    }

    function createReferralWithPermit(
        address referrer_,
        bytes32 code_,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        IERC2612Permit(rewardToken).permit(msg.sender, address(this), fee, expiry, v, r, s);

        _createReferral(referrer_, code_);
    }

    function createReferral(address referrer_, bytes32 code_) external {
        _createReferral(referrer_, code_);
    }

    function _createReferral(address referrer_, bytes32 code_) internal {
        require(referrer_ != address(0), "Referrer cannot be zero");
        require(code_ != bytes32(""), "Code cannot be zero");
        require(referrals[code_] == address(0), "Code already exists");

        referrals[code_] = referrer_;

        // Charge the fee
        IERC20(rewardToken).safeTransferFrom(msg.sender, treasury, fee);

        emit LogNewReferral(referrer_, code_);
    }

    function claimRewards(bytes32 code_) external {
        address recipient = referrals[code_];
        require(recipient == msg.sender, "Not owner");

        uint256 amount = rewards[code_];
        if (amount > 0 && IERC20(rewardToken).balanceOf(address(this)) >= amount) {
            rewards[code_] = 0;
            IERC20(rewardToken).safeTransfer(recipient, amount);
        }

        emit LogClaim(recipient, amount);
    }

    function calcRewards(
        bytes32 code_,
        uint256 payout_,
        address depositor_
    ) external view returns (uint256 referrerReward_, uint256 depositorReward_) {
        if (
            referrals[code_] == address(0) || // code not registered
            referrals[code_] == depositor_ // depositor is code owner
        ) {
            // referral code doesn't exist
            referrerReward_ = depositorReward_ = 0;
        } else {
            referrerReward_ = payout_.mul(referrerShare).div(10000);
            depositorReward_ = payout_.mul(depositorShare).div(10000);
        }
    }

    function depositRewards(bytes32 code_, uint256 rewards_) external {
        if (rewards_ > 0 && referrals[code_] != address(0)) {
            rewards[code_] = rewards[code_].add(rewards_);
            IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rewards_);
        }
        emit LogDepositRewards(msg.sender, referrals[code_], rewards_);
    }

    function setRewardToken(address rewardToken_) external onlyOwner() {
        require(rewardToken_ != address(0));
        rewardToken = rewardToken_;
    }

    function setTreasury(address treasury_) external onlyOwner() {
        require(treasury_ != address(0));
        treasury = treasury_;
    }

    function setFee(uint256 fee_) external onlyOwner() {
        fee = fee_;
    }

    function setRewardShares(uint256 referrerShare_, uint256 depositorShare_) external onlyOwner() {
        referrerShare = referrerShare_;
        depositorShare = depositorShare_;
    }
}

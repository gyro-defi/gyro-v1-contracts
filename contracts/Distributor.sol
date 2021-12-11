pragma solidity ^0.7.5;

import "./libs/SafeMath.sol";
import "./libs/Ownable.sol";
import "./libs/IERC20.sol";
import "./libs/SafeERC20.sol";

import "./interfaces/IReservoir.sol";

contract Distributor is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ====== STRUCTS ====== */

    struct Info {
        uint256 rate; // in ten-thousandths ( 5000 = 0.5% )
        address recipient;
    }
    Info[] public info;

    struct Adjustment {
        bool add;
        uint256 rate;
        uint256 target;
    }

    /* ====== VARIABLES ====== */

    address public immutable gyro;
    address public immutable reservoir;

    uint256 public immutable epochLength;
    uint256 public nextEpochBlock;

    mapping(uint256 => Adjustment) public adjustments;

    /* ======== EVENTS ======== */

    event LogAddRecipient(address indexed recipient_, uint256 position, uint256 rewardRate_);
    event LogRemoveRecipient(address indexed recipient_, uint256 index_);

    /* ====== CONSTRUCTOR ====== */

    constructor(
        address reservoir_,
        address gyro_,
        uint256 epochLength_,
        uint256 nextEpochBlock_
    ) {
        require(reservoir_ != address(0));
        reservoir = reservoir_;
        require(gyro_ != address(0));
        gyro = gyro_;
        epochLength = epochLength_;
        if (nextEpochBlock_ == 0) nextEpochBlock_ = block.number;
        nextEpochBlock = nextEpochBlock_;
    }

    /* ====== PUBLIC FUNCTIONS ====== */

    /**
        @notice send epoch reward to staking contract
     */
    function distribute() external returns (bool) {
        if (nextEpochBlock > block.number) {
            // still in current epoch, pass
            return false;
        }

        nextEpochBlock = nextEpochBlock.add(epochLength); // set next epoch block

        // distribute rewards to each recipient
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].rate > 0) {
                // mint and send from reservoir
                uint256 rewards = IReservoir(reservoir).mintRewards(info[i].recipient, nextRewardAt(info[i].rate));
                if (rewards > 0) adjust(i); // check for adjustment if rewards are minted
            }
        }

        return true;
    }

    /* ====== INTERNAL FUNCTIONS ====== */

    /**
        @notice increment reward rate for collector
     */
    function adjust(uint256 index_) internal {
        Adjustment memory adjustment = adjustments[index_];
        if (adjustment.rate != 0) {
            if (adjustment.add) {
                // if rate should increase
                info[index_].rate = info[index_].rate.add(adjustment.rate); // raise rate
                if (info[index_].rate >= adjustment.target) {
                    // if target met
                    adjustments[index_].rate = 0; // turn off adjustment
                }
            } else {
                // if rate should decrease
                info[index_].rate = info[index_].rate.sub(adjustment.rate); // lower rate
                if (info[index_].rate <= adjustment.target) {
                    // if target met
                    adjustments[index_].rate = 0; // turn off adjustment
                }
            }
        }
    }

    /* ====== VIEW FUNCTIONS ====== */

    /**
        @notice view function for next reward at given rate
        @param rate_ uint
        @return uint
     */
    function nextRewardAt(uint256 rate_) public view returns (uint256) {
        return IERC20(gyro).totalSupply().mul(rate_).div(1000000);
    }

    /**
        @notice view function for next reward for specified address
        @param recipient_ address
        @return uint
     */
    function nextRewardFor(address recipient_) public view returns (uint256) {
        uint256 reward = 0;
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].recipient == recipient_) {
                reward = nextRewardAt(info[i].rate);
            }
        }
        return reward;
    }

    /* ====== POLICY FUNCTIONS ====== */

    /**
        @notice adds recipient for distributions
        @param recipient_ address
        @param rewardRate_ uint
     */
    function addRecipient(address recipient_, uint256 rewardRate_) external onlyOwner() {
        require(recipient_ != address(0));
        info.push(Info({recipient: recipient_, rate: rewardRate_}));

        emit LogAddRecipient(recipient_, info.length - 1, rewardRate_);
    }

    /**
        @notice removes recipient for distributions
        @param index_ uint
        @param recipient_ address
     */
    function removeRecipient(uint256 index_, address recipient_) external onlyOwner() {
        if (index_ >= info.length) return;
        require(recipient_ == info[index_].recipient, "Recipient not exists");

        info[index_].recipient = info[info.length - 1].recipient;
        info[index_].rate = info[info.length - 1].rate;

        delete info[info.length - 1];
        info.pop();

        emit LogRemoveRecipient(recipient_, index_);
    }

    /**
        @notice set adjustment info for a collector's reward rate
        @param index_ uint
        @param add_ bool
        @param rate_ uint
        @param target_ uint
     */
    function setAdjustment(
        uint256 index_,
        bool add_,
        uint256 rate_,
        uint256 target_
    ) external onlyOwner() {
        adjustments[index_] = Adjustment({add: add_, rate: rate_, target: target_});
    }
}

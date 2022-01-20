pragma solidity ^0.7.5;

import "./libs/SafeMath.sol";
import "./libs/Ownable.sol";
import "./libs/IERC20.sol";
import "./libs/SafeERC20.sol";
import "./libs/IERC2612Permit.sol";

interface ISGyro {
    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function rebase(uint256 profit, uint256 epoch) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function gonsForBalance(uint256 amount) external view returns (uint256);

    function balanceForGons(uint256 gons) external view returns (uint256);

    function index() external view returns (uint256);
}

interface IEscrow {
    function retrieve(address recipient, uint256 amount) external;
}

interface IDistributor {
    function distribute() external returns (bool);
}

contract GyroVault is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable gyro;
    address public immutable sGyro;

    struct Epoch {
        uint256 period;
        uint256 number;
        uint256 nextBlock;
        uint256 distribute;
    }
    Epoch public epoch;

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock; // prevents malicious delays
    }
    mapping(address => Claim) public stakeInfo;

    address public distributor;

    address public locker;
    uint256 public totalBonus;

    address public escrowContract;
    uint256 public escrowPeriod; // in epochs

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    event LogStake(address indexed depositer, address indexed recipient, uint256 amount, uint256 expiry);
    event LogRedeem(address indexed recipient, uint256 amount, bool trigger);
    event LogClaim(address indexed recipient, uint256 amount);
    event LogForfeit(address indexed recipient, uint256 amount);
    event LogRebase(uint256 epochNumber, uint256 epochNextBlock, uint256 distribution);

    constructor(
        address gyro_,
        address sGyro_,
        uint256 epochLength_,
        uint256 firstEpochNumber_,
        uint256 firstEpochBlock_
    ) {
        require(gyro_ != address(0));
        gyro = gyro_;
        require(sGyro_ != address(0));
        sGyro = sGyro_;
        require(epochLength_ > 0, "Epoch period should be greater than 0");
        if (firstEpochBlock_ == 0) firstEpochBlock_ = block.number + epochLength_;
        epoch = Epoch({period: epochLength_, number: firstEpochNumber_, nextBlock: firstEpochBlock_, distribute: 0});
    }

    function stakeWithPermit(
        address recipient_,
        uint256 amount_,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external lock returns (uint256) {
        IERC2612Permit(gyro).permit(msg.sender, address(this), amount_, expiry, v, r, s);
        return _stake(amount_, recipient_);
    }

    function stake(uint256 amount_, address recipient_) external lock returns (uint256) {
        return _stake(amount_, recipient_);
    }

    /**
        @notice stake gyro to enter escrow
        @param amount_ uint
        @param recipient_ address
        @return uint256
     */
    function _stake(uint256 amount_, address recipient_) internal returns (uint256) {
        require(recipient_ != address(0), "Recipient undefined");

        Claim memory info = stakeInfo[recipient_];
        require(!info.lock, "Deposits for account are locked");

        rebase();

        IERC20(gyro).safeTransferFrom(msg.sender, address(this), amount_);

        uint256 expiryEpoch = epoch.number.add(escrowPeriod);
        uint256 totalDeposit = info.deposit.add(amount_);

        if (escrowPeriod > 0) {
            stakeInfo[recipient_] = Claim({
                deposit: totalDeposit,
                gons: info.gons.add(ISGyro(sGyro).gonsForBalance(amount_)),
                expiry: expiryEpoch,
                lock: false
            });

            IERC20(sGyro).safeTransfer(escrowContract, amount_);
        } else {
            IERC20(sGyro).safeTransfer(recipient_, amount_);
        }

        emit LogStake(msg.sender, recipient_, amount_, expiryEpoch);

        return totalDeposit;
    }

    /**
        @notice retrieve sGyro from escrow
        @param recipient_ address
     */
    function claim(address recipient_) external lock {
        Claim memory info = stakeInfo[recipient_];
        if (info.gons > 0 && epoch.number >= info.expiry) {
            uint256 amount = ISGyro(sGyro).balanceForGons(info.gons);
            delete stakeInfo[recipient_];
            IEscrow(escrowContract).retrieve(recipient_, amount);
            emit LogClaim(recipient_, amount);
        }
    }

    /**
        @notice forfeit sGyro in escrow and retrieve gyro
     */
    function forfeit() external lock {
        Claim memory info = stakeInfo[msg.sender];
        if (info.gons > 0) {
            delete stakeInfo[msg.sender];
            uint256 amount = ISGyro(sGyro).balanceForGons(info.gons);
            IEscrow(escrowContract).retrieve(address(this), amount);
            IERC20(gyro).safeTransfer(msg.sender, info.deposit);
            emit LogForfeit(msg.sender, amount);
        }
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        stakeInfo[msg.sender].lock = !stakeInfo[msg.sender].lock;
    }

    function redeemWithPermit(
        uint256 amount_,
        bool trigger_,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external lock {
        IERC2612Permit(sGyro).permit(msg.sender, address(this), amount_, expiry, v, r, s);

        _redeem(amount_, trigger_);
    }

    /**
        @notice redeem sGyro for gyro
        @param amount_ uint
        @param trigger_ bool
     */
    function redeem(uint256 amount_, bool trigger_) external lock {
        _redeem(amount_, trigger_);
    }

    function _redeem(uint256 amount_, bool trigger_) internal {
        require(amount_ <= contractBalance(), "Insufficient contract balance");
        if (trigger_) {
            rebase();
        }
        IERC20(sGyro).safeTransferFrom(msg.sender, address(this), amount_);
        IERC20(gyro).safeTransfer(msg.sender, amount_);

        emit LogRedeem(msg.sender, amount_, trigger_);
    }

    /**
        @notice returns the sGyro index, which tracks rebase growth
        @return uint
     */
    function index() public view returns (uint256) {
        return ISGyro(sGyro).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if (epoch.nextBlock <= block.number) {
            ISGyro(sGyro).rebase(epoch.distribute, epoch.number);

            epoch.nextBlock = epoch.nextBlock.add(epoch.period);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();
            uint256 staked = ISGyro(sGyro).circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked);
            }

            emit LogRebase(epoch.number, epoch.nextBlock, epoch.distribute);
        }
    }

    /**
        @notice returns contract gyro holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns (uint256) {
        return IERC20(gyro).balanceOf(address(this)).add(totalBonus);
    }

    /**
        @notice provide bonus to locked staking contract
        @param amount_ uint
     */
    function giveLockBonus(uint256 amount_) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.add(amount_);
        IERC20(sGyro).safeTransfer(locker, amount_);
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param amount_ uint
     */
    function returnLockBonus(uint256 amount_) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.sub(amount_);
        IERC20(sGyro).safeTransferFrom(locker, address(this), amount_);
    }

    enum CONTRACTS {DISTRIBUTOR, ESCROW, LOCKER}

    /**
        @notice sets the contract address for LP staking
        @param contract_ address
     */
    function setContract(CONTRACTS contract_, address address_) external onlyOwner() {
        if (contract_ == CONTRACTS.DISTRIBUTOR) {
            // 0
            distributor = address_;
        } else if (contract_ == CONTRACTS.ESCROW) {
            // 1
            require(escrowContract == address(0), "Escrow cannot be set more than once");
            escrowContract = address_;
        } else if (contract_ == CONTRACTS.LOCKER) {
            // 2
            require(locker == address(0), "Locker cannot be set more than once");
            locker = address_;
        }
    }

    /**
     * @notice set escrow period for new stakers
     * @param escrowPeriod_ uint
     */
    function setEscrowPeriod(uint256 escrowPeriod_) external onlyOwner() {
        escrowPeriod = escrowPeriod_;
    }
}

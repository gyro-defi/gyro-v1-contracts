pragma solidity ^0.7.5;

import "./libs/Ownable.sol";
import "./libs/SafeMath.sol";
import "./libs/Address.sol";
import "./libs/ERC20Permit.sol";
import "./libs/SafeERC20.sol";
import "./libs/FixedPoint.sol";

import "./interfaces/IBondCalculator.sol";
import "./interfaces/IReservoir.sol";

interface IGyroVault {
    function stake(uint256 amount_, address recipient_) external returns (uint256);
}

interface IReferral {
    function calcRewards(
        bytes32 code_,
        uint256 payout_,
        address depositor_
    ) external view returns (uint256, uint256);

    function depositRewards(bytes32 code_, uint256 rewards_) external;
}

contract GyroBond is Ownable {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ======== EVENTS ======== */

    event LogBondCreated(uint256 deposit, uint256 indexed payout, uint256 indexed expires, uint256 indexed priceInUSD);
    event LogBondRedeemed(address indexed recipient, uint256 payout, uint256 remaining);
    event LogBondPriceChanged(uint256 indexed priceInUSD, uint256 indexed internalPrice, uint256 indexed debtRatio);
    event LogControlVariableAdjustment(uint256 initialBCV, uint256 newBCV, uint256 adjustment, bool addition);

    /* ======== STATE VARIABLES ======== */

    address public immutable gyro; // token given as payment for bond
    address public immutable tokenIn; // token used to create bond
    address public immutable reservoir; // mints gyro when receives principle
    address public immutable treasury; // receives profit share from bond

    bool public immutable isLiquidityBond; // LP and Reserve bonds are treated slightly different
    address public immutable bondCalculator; // calculates value of LP tokens

    address public vault; // to auto-stake payout

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping(address => Bond) public bondInfo; // stores bond information for depositors

    uint256 public totalDebt; // total value of outstanding bonds; used for pricing
    uint256 public lastDecay; // reference block for debt decay

    address public referral; // referral manager

    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint256 controlVariable; // scaling variable for price
        uint256 period; // in blocks
        uint256 minPrice; // vs principle value
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
    }

    // Info for bond holder
    struct Bond {
        uint256 payout; // gyro remaining to be paid
        uint256 period; // Blocks left to vest
        uint256 lastBlock; // Last interaction
        uint256 pricePaid; // In usd, for front end viewing
    }

    // Info for incremental adjustments to control variable
    struct Adjust {
        bool add; // addition or subtraction
        uint256 rate; // increment
        uint256 target; // BCV when adjustment finished
        uint256 buffer; // minimum length (in blocks) between adjustments
        uint256 lastBlock; // block when last adjustment made
    }

    /* ======== INITIALIZATION ======== */

    constructor(
        address gyro_,
        address tokenIn_,
        address reservoir_,
        address treasury_,
        address bondCalculator_
    ) {
        require(gyro_ != address(0));
        gyro = gyro_;
        require(tokenIn_ != address(0));
        tokenIn = tokenIn_;
        require(reservoir_ != address(0));
        reservoir = reservoir_;
        require(treasury_ != address(0));
        treasury = treasury_;
        // bondCalculator should be address(0) if not LP bond
        bondCalculator = bondCalculator_;
        isLiquidityBond = (bondCalculator_ != address(0));
    }

    /**
     *  @notice initializes bond parameters
     *  @param controlVariable_ uint
     *  @param period_ uint
     *  @param minPrice_ uint
     *  @param maxPayout_ uint
     *  @param fee_ uint
     *  @param maxDebt_ uint
     *  @param initialDebt_ uint
     */
    function initializeBondTerms(
        uint256 controlVariable_,
        uint256 period_,
        uint256 minPrice_,
        uint256 maxPayout_,
        uint256 fee_,
        uint256 maxDebt_,
        uint256 initialDebt_
    ) external onlyOwner() {
        require(terms.controlVariable == 0, "Bonds must be initialized from 0");
        terms = Terms({
            controlVariable: controlVariable_,
            period: period_,
            minPrice: minPrice_,
            maxPayout: maxPayout_,
            fee: fee_,
            maxDebt: maxDebt_
        });
        totalDebt = initialDebt_;
        lastDecay = block.number;
    }

    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER {VESTING, PAYOUT, FEE, DEBT}

    /**
     *  @notice set parameters for new bonds
     *  @param parameter_ PARAMETER
     *  @param input_ uint
     */
    function setBondTerms(PARAMETER parameter_, uint256 input_) external onlyOwner() {
        if (parameter_ == PARAMETER.VESTING) {
            // 0
            require(input_ >= 40000, "Vesting must be longer than 36 hours"); // assuming, 3s block time
            terms.period = input_;
        } else if (parameter_ == PARAMETER.PAYOUT) {
            // 1
            require(input_ <= 1000, "Payout cannot be above 1 percent");
            terms.maxPayout = input_;
        } else if (parameter_ == PARAMETER.FEE) {
            // 2
            require(input_ <= 10000, "Treasury fee cannot exceed payout");
            terms.fee = input_;
        } else if (parameter_ == PARAMETER.DEBT) {
            // 3
            terms.maxDebt = input_;
        }
    }

    /**
     *  @notice set control variable adjustment
     *  @param addition_ bool
     *  @param increment_ uint
     *  @param target_ uint
     *  @param buffer_ uint
     */
    function setAdjustment(
        bool addition_,
        uint256 increment_,
        uint256 target_,
        uint256 buffer_
    ) external onlyOwner() {
        require(increment_ <= terms.controlVariable.mul(25).div(1000), "Increment too large");

        adjustment = Adjust({
            add: addition_,
            rate: increment_,
            target: target_,
            buffer: buffer_,
            lastBlock: block.number
        });
    }

    /**
     *  @notice set contract for auto stake
     *  @param vault_ address
     */
    function setVault(address vault_) external onlyOwner() {
        require(vault_ != address(0), "Vault cannot be zero address");
        vault = vault_;
    }

    /**
     *  @notice set contract for referrals
     *  @param referral_ address
     */
    function setReferral(address referral_) external onlyOwner() {
        referral = referral_;
    }

    /* ======== USER FUNCTIONS ======== */

    struct DepositVars {
        uint256 bondPrice;
        uint256 bondPriceInUSD;
        uint256 value;
        uint256 payout;
        uint256 fee;
        uint256 profit;
        uint256 referrerRewards;
        uint256 depositorRewards;
    }

    /**
     *  @notice deposit bond
     *  @param amount_ uint
     *  @param maxPrice_ uint
     *  @param depositor_ address
     *  @param referralCode_ address
     *  @return uint
     */
    function deposit(
        uint256 amount_,
        uint256 maxPrice_,
        address depositor_,
        bytes32 referralCode_
    ) external returns (uint256) {
        require(depositor_ != address(0), "Invalid address");

        _decayDebt();

        require(totalDebt <= terms.maxDebt, "Max capacity reached");

        DepositVars memory vars;

        require(maxPrice_ >= bondPrice(), "Slippage limit: more than max price"); // slippage protection

        (vars.payout, vars.value) = payoutFor(amount_); // payout to bonder is computed

        require(vars.payout >= 10000000, "Bond too small"); // must be > 0.01 gyro ( underflow protection )
        require(vars.payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        vars.referrerRewards = 0;
        vars.depositorRewards = 0;
        if (referral != address(0) && referralCode_ != bytes32("")) {
            (vars.referrerRewards, vars.depositorRewards) = IReferral(referral).calcRewards(
                referralCode_,
                vars.payout,
                depositor_
            );
        }
        vars.fee = vars.payout.mul(terms.fee).div(10000);
        // profits are calculated
        vars.profit = 0;
        if (vars.value > vars.payout.add(vars.fee).add(vars.referrerRewards).add(vars.depositorRewards)) {
            // only payout referral rewards if there's enough profit
            vars.profit = vars.value.sub(vars.payout).sub(vars.fee).sub(vars.referrerRewards).sub(
                vars.depositorRewards
            );
        } else if (vars.value > vars.payout.add(vars.fee)) {
            vars.profit = vars.value.sub(vars.payout).sub(vars.fee);
            vars.referrerRewards = 0;
            vars.depositorRewards = 0;
        } else {
            vars.profit = vars.value.sub(vars.payout);
            vars.fee = 0;
            vars.referrerRewards = 0;
            vars.depositorRewards = 0;
        }

        // total debt is increased
        totalDebt = totalDebt.add(vars.value);

        vars.bondPriceInUSD = bondPriceInUSD();

        // depositor info is stored
        bondInfo[depositor_] = Bond({
            payout: bondInfo[depositor_].payout.add(vars.payout).add(vars.depositorRewards),
            period: terms.period,
            lastBlock: block.number,
            pricePaid: vars.bondPriceInUSD
        });

        _adjust(); // control variable is adjusted

        vars.bondPrice = _updateBondPrice();

        /**
            principle is transferred in
            approved and
            deposited into the reservoir
         */
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount_);
        IERC20(tokenIn).safeIncreaseAllowance(address(reservoir), amount_);
        uint256 gyroMinted = IReservoir(reservoir).bondDeposit(amount_, vars.profit);

        require(gyroMinted >= vars.value.sub(vars.profit), "Deposit failed");

        if (vars.fee > 0) {
            // fee is transferred to treasury
            IERC20(gyro).safeTransfer(treasury, vars.fee);
        }

        if (vars.referrerRewards > 0) {
            IERC20(gyro).safeIncreaseAllowance(referral, vars.referrerRewards);
            IReferral(referral).depositRewards(referralCode_, vars.referrerRewards);
        }

        // indexed events are emitted
        emit LogBondCreated(amount_, vars.payout, block.number.add(terms.period), vars.bondPriceInUSD);
        emit LogBondPriceChanged(vars.bondPriceInUSD, vars.bondPrice, debtRatio());

        return vars.payout;
    }

    /**
     *  @notice redeem bond for user
     *  @param recipient_ address
     *  @param stake_ bool
     *  @return uint
     */
    function redeem(address recipient_, bool stake_) external returns (uint256) {
        Bond memory info = bondInfo[recipient_];
        uint256 percentVested = percentVestedFor(recipient_); // (blocks since last interaction / vesting period remaining)

        if (percentVested >= 10000) {
            // if fully vested
            delete bondInfo[recipient_]; // delete user info
            emit LogBondRedeemed(recipient_, info.payout, 0); // emit bond data
            return _stakeOrSend(recipient_, stake_, info.payout); // pay user everything due
        } else {
            // if unfinished
            // calculate payout vested
            uint256 payout = info.payout.mul(percentVested).div(10000);

            // store updated deposit info
            bondInfo[recipient_] = Bond({
                payout: info.payout.sub(payout),
                period: info.period.sub(block.number.sub(info.lastBlock)),
                lastBlock: block.number,
                pricePaid: info.pricePaid
            });

            emit LogBondRedeemed(recipient_, payout, bondInfo[recipient_].payout);
            return _stakeOrSend(recipient_, stake_, payout);
        }
    }

    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param recipient_ address
     *  @param stake_ bool
     *  @param amount_ uint
     *  @return uint
     */
    function _stakeOrSend(
        address recipient_,
        bool stake_,
        uint256 amount_
    ) internal returns (uint256) {
        if (!stake_) {
            // if user does not want to stake
            IERC20(gyro).safeTransfer(recipient_, amount_); // send payout
        } else {
            // if user wants to stake
            IERC20(gyro).safeIncreaseAllowance(vault, amount_);
            uint256 totalStaked = IGyroVault(vault).stake(amount_, recipient_);
            require(totalStaked >= amount_, "Stake failed");
        }
        return amount_;
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function _adjust() internal {
        uint256 blockCanAdjust = adjustment.lastBlock.add(adjustment.buffer);
        if (adjustment.rate != 0 && block.number >= blockCanAdjust) {
            uint256 initial = terms.controlVariable;
            if (adjustment.add) {
                terms.controlVariable = terms.controlVariable.add(adjustment.rate);
                if (terms.controlVariable >= adjustment.target) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub(adjustment.rate);
                if (terms.controlVariable <= adjustment.target) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastBlock = block.number;
            emit LogControlVariableAdjustment(initial, terms.controlVariable, adjustment.rate, adjustment.add);
        }
    }

    /**
     *  @notice reduce total debt
     */
    function _decayDebt() internal {
        totalDebt = totalDebt.sub(debtDecay());
        lastDecay = block.number;
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns (uint256) {
        return IERC20(gyro).totalSupply().mul(terms.maxPayout).div(100000);
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param amount_ uint
     *  @return payout_ uint, value_ uint
     */
    function payoutFor(uint256 amount_) public view returns (uint256 payout_, uint256 value_) {
        (value_, ) = gyroValue(amount_);
        payout_ = FixedPoint.fraction(value_, bondPrice()).decode112with18().div(1e16);
    }

    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).add(1000000000).div(1e7);
        if (price_ < terms.minPrice) {
            price_ = terms.minPrice;
        }
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _updateBondPrice() internal returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).add(1000000000).div(1e7);
        if (price_ < terms.minPrice) {
            price_ = terms.minPrice;
        } else if (terms.minPrice != 0) {
            terms.minPrice = 0;
        }
    }

    /**
     *  @notice converts bond price to usd value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns (uint256 price_) {
        if (isLiquidityBond) {
            price_ = bondPrice().mul(IBondCalculator(bondCalculator).markdown(tokenIn, gyro)).div(100);
        } else {
            price_ = bondPrice().mul(10**IERC20(tokenIn).decimals()).div(100);
        }
    }

    /**
     *  @notice returns gyro valuation of asset
     *  @param amount_ uint
     *   @return value_ uint
     */
    function gyroValue(uint256 amount_) public view returns (uint256 value_, address token_) {
        if (isLiquidityBond) {
            value_ = IBondCalculator(bondCalculator).valuation(tokenIn, amount_);
        } else {
            // convert amount to match gyro decimals
            value_ = amount_.mul(10**IERC20(gyro).decimals()).div(10**IERC20(tokenIn).decimals());
        }
        token_ = tokenIn;
    }

    /**
     *  @notice calculate current ratio of debt to gyro supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns (uint256 debtRatio_) {
        uint256 supply = IERC20(gyro).totalSupply();
        debtRatio_ = FixedPoint.fraction(currentDebt().mul(1e9), supply).decode112with18().div(1e18);
    }

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns (uint256) {
        if (isLiquidityBond) {
            return debtRatio().mul(IBondCalculator(bondCalculator).markdown(tokenIn, gyro)).div(1e9);
        } else {
            return debtRatio();
        }
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns (uint256) {
        return totalDebt.sub(debtDecay());
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns (uint256 decay_) {
        uint256 blocksSinceLast = block.number.sub(lastDecay);
        decay_ = totalDebt.mul(blocksSinceLast).div(terms.period);
        if (decay_ > totalDebt) {
            decay_ = totalDebt;
        }
    }

    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param depositor_ address
     *  @return percentVested_ uint
     */
    function percentVestedFor(address depositor_) public view returns (uint256 percentVested_) {
        Bond memory bond = bondInfo[depositor_];
        uint256 blocksSinceLast = block.number.sub(bond.lastBlock);
        uint256 period = bond.period;

        if (period > 0) {
            percentVested_ = blocksSinceLast.mul(10000).div(period);
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of gyro available for claim by depositor
     *  @param depositor_ address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor(address depositor_) external view returns (uint256 pendingPayout_) {
        uint256 percentVested = percentVestedFor(depositor_);
        uint256 payout = bondInfo[depositor_].payout;

        if (percentVested >= 10000) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout.mul(percentVested).div(10000);
        }
    }

    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding gyro or principle token) to the treasury
     *  @return bool
     */
    function recoverLostToken(address token_) external returns (bool) {
        require(token_ != gyro);
        require(token_ != tokenIn);
        IERC20(token_).safeTransfer(treasury, IERC20(token_).balanceOf(address(this)));
        return true;
    }
}

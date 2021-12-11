pragma solidity ^0.7.5;

import "./libs/SafeMath.sol";
import "./libs/Ownable.sol";
import "./libs/IERC20.sol";
import "./libs/SafeERC20.sol";

contract PrivateSale is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event RateSet(uint256 oldRate, uint256 newRate);
    event BuyerApproval(address indexed buyer);

    IERC20 public tokenIn;

    IERC20 public pGyro;

    address private treasury;

    uint256 public pGyroRate;

    mapping(address => bool) public approvedBuyers;

    constructor(
        address pGyro_,
        address tokenIn_,
        uint256 pGyroRate_,
        address treasury_
    ) {
        pGyro = IERC20(pGyro_);
        tokenIn = IERC20(tokenIn_);
        pGyroRate = pGyroRate_;
        treasury = treasury_;
    }

    function setRate(uint256 newRate) external onlyOwner() returns (uint256) {
        uint256 oldRate = pGyroRate;
        pGyroRate = newRate;

        emit RateSet(oldRate, pGyroRate);

        return pGyroRate;
    }

    function _approveBuyer(address newBuyer_) internal onlyOwner() returns (bool) {
        approvedBuyers[newBuyer_] = true;
        emit BuyerApproval(newBuyer_);

        return approvedBuyers[newBuyer_];
    }

    function approveBuyer(address newBuyer_) external onlyOwner() returns (bool) {
        return _approveBuyer(newBuyer_);
    }

    function approveBuyers(address[] calldata newBuyers_) external onlyOwner() returns (uint256) {
        for (uint256 iteration_ = 0; newBuyers_.length > iteration_; iteration_++) {
            _approveBuyer(newBuyers_[iteration_]);
        }
        return newBuyers_.length;
    }

    function _calcAmountRaised(uint256 amountPaid_) internal view returns (uint256) {
        return amountPaid_.mul(pGyroRate);
    }

    function buyGyro(uint256 amountPaid_) external returns (bool) {
        require(approvedBuyers[msg.sender], "Buyer not approved.");
        uint256 amountRaised = _calcAmountRaised(amountPaid_);
        tokenIn.safeTransferFrom(msg.sender, treasury, amountPaid_);
        pGyro.safeTransfer(msg.sender, amountRaised);
        return true;
    }

    function withdrawTokens(address tokenToWithdraw_) external onlyOwner() returns (bool) {
        IERC20(tokenToWithdraw_).safeTransfer(msg.sender, IERC20(tokenToWithdraw_).balanceOf(address(this)));
        return true;
    }
}

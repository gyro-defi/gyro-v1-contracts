pragma solidity ^0.7.5;

import "./libs/Ownable.sol";
import "./libs/IERC20.sol";
import "./libs/SafeERC20.sol";
import "./libs/SafeMath.sol";

contract vGyroVault is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public immutable redeemEndBlock;

    IERC20 public immutable gyro;
    IERC20 public immutable vGyro;

    mapping(address => uint256) public userInfo;

    modifier redemptionEnded() {
        require(block.number > redeemEndBlock, "Redemption period has not ended");
        _;
    }

    modifier redemptionNotEnd() {
        require(block.number < redeemEndBlock, "Redemption period has ended");
        _;
    }

    constructor(
        address gyro_,
        address vGyro_,
        uint256 redeemPeriod_ // in blocks
    ) {
        require(gyro_ != address(0), "Address cannot be zero");
        gyro = IERC20(gyro_);
        require(vGyro_ != address(0), "Address cannot be zero");
        vGyro = IERC20(vGyro_);
        redeemEndBlock = block.number.add(redeemPeriod_);
    }

    function redeem(uint256 amount) external redemptionNotEnd() {
        require(vGyro.balanceOf(msg.sender) >= amount, "Not enough balance");

        userInfo[msg.sender] = userInfo[msg.sender].add(amount);

        vGyro.safeTransferFrom(msg.sender, address(this), amount);
        gyro.safeTransfer(msg.sender, amount);
    }

    function reclaim() external redemptionEnded() {
        require(userInfo[msg.sender] > 0, "No vGyro to withdraw");

        uint256 amount = userInfo[msg.sender];
        userInfo[msg.sender] = 0;
        vGyro.safeTransfer(msg.sender, amount);
    }

    function withdraw() external onlyOwner() redemptionEnded() {
        uint256 amount = gyro.balanceOf(address(this));
        gyro.safeTransfer(msg.sender, amount);
    }
}

pragma solidity ^0.7.5;

import "./libs/Ownable.sol";
import "./libs/SafeMath.sol";
import "./libs/SafeERC20.sol";
import "./libs/IUniswapV2Pair.sol";

import "./interfaces/IGyroBond.sol";

interface IUniswapV2Router02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );
}

contract GyroBondHelper is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable bond;
    address public immutable router;

    constructor(address bond_, address router_) {
        require(bond_ != address(0), "Router cannot be zero");
        bond = bond_;
        require(router_ != address(0), "Router cannot be zero");
        router = router_;
    }

    struct DepositVars {
        address lpToken;
        uint256 prevToken0Bal;
        uint256 currToken0Bal;
        uint256 prevToken1Bal;
        uint256 currToken1Bal;
    }

    function deposit(
        address recipient_,
        uint256 amount0_,
        uint256 amount1_,
        uint256 amount0Min_,
        uint256 amount1Min_,
        uint256 deadline_,
        uint256 maxPrice_,
        bytes32 referralCode_
    ) external {
        require(recipient_ != address(0), "Recipient cannot be zero");
        require(amount0_ > 0, "Amount should be greater than 0");
        require(amount1_ > 0, "Amount should be greater than 0");

        DepositVars memory vars;

        vars.lpToken = IGyroBond(bond).tokenIn();
        require(vars.lpToken != address(0), "Bond principle undefined");

        address token0 = IUniswapV2Pair(vars.lpToken).token0();
        address token1 = IUniswapV2Pair(vars.lpToken).token1();

        // save previous balances

        vars.prevToken0Bal = IERC20(token0).balanceOf(address(this));
        vars.prevToken1Bal = IERC20(token1).balanceOf(address(this));

        // get the tokens from the depositor

        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0_);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1_);

        // add liquidity to the router

        IERC20(token0).safeIncreaseAllowance(router, amount0_);
        IERC20(token1).safeIncreaseAllowance(router, amount1_);

        (, , uint256 liquidity) =
            IUniswapV2Router02(router).addLiquidity(
                token0,
                token1,
                amount0_,
                amount1_,
                amount0Min_,
                amount1Min_,
                address(this),
                deadline_
            );

        // make sure we have enough liquidity to deposit to the bond

        require(liquidity > 0, "Not enough liquidity");

        IERC20(vars.lpToken).safeIncreaseAllowance(bond, liquidity);
        IGyroBond(bond).deposit(liquidity, maxPrice_, recipient_, referralCode_);

        // return the remaining tokens to the depositor

        vars.currToken0Bal = IERC20(token0).balanceOf(address(this));
        vars.currToken1Bal = IERC20(token1).balanceOf(address(this));
        if (vars.currToken0Bal > vars.prevToken0Bal) {
            IERC20(token0).safeTransfer(msg.sender, vars.currToken0Bal.sub(vars.prevToken0Bal));
        }
        if (vars.currToken1Bal > vars.prevToken1Bal) {
            IERC20(token1).safeTransfer(msg.sender, vars.currToken1Bal.sub(vars.prevToken1Bal));
        }
    }

    /**
     *  @notice allow anyone to send lost tokens to the owner
     */
    function recoverLostToken(address token_) external onlyOwner() {
        IERC20(token_).safeTransfer(msg.sender, IERC20(token_).balanceOf(address(this)));
    }
}

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

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract GyroBondPCSHelper is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable router;

    constructor(address router_) {
        require(router_ != address(0), "Router cannot be zero");
        router = router_;
    }

    struct DepositVars {
        address lpToken;
        address bond;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 prevToken0Bal;
        uint256 prevToken1Bal;
        uint256 deadline;
        uint256 maxPrice;
        bytes32 referralCode;
    }

    function deposit(
        address recipient_,
        address bond_,
        uint256 amount0_,
        uint256 amount1_,
        uint256 amount0Min_,
        uint256 amount1Min_,
        uint256 deadline_,
        uint256 maxPrice_,
        bytes32 referralCode_
    ) external {
        require(recipient_ != address(0), "Recipient cannot be zero");
        require(bond_ != address(0), "Bond cannot be zero");
        require(amount0_ > 0, "Amount should be greater than 0");
        require(amount1_ > 0, "Amount should be greater than 0");

        DepositVars memory vars;

        vars.bond = bond_;
        vars.amount0Min = amount0Min_;
        vars.amount1Min = amount1Min_;
        vars.deadline = deadline_;
        vars.maxPrice = maxPrice_;
        vars.referralCode = referralCode_;
        vars.amount0 = amount0_;
        vars.amount1 = amount1_;

        vars.lpToken = IGyroBond(vars.bond).tokenIn();
        require(vars.lpToken != address(0), "Bond principle undefined");

        vars.token0 = IUniswapV2Pair(vars.lpToken).token0();
        vars.token1 = IUniswapV2Pair(vars.lpToken).token1();

        // save previous balances

        vars.prevToken0Bal = IERC20(vars.token0).balanceOf(address(this));
        vars.prevToken1Bal = IERC20(vars.token1).balanceOf(address(this));

        // get the tokens from the depositor

        IERC20(vars.token0).safeTransferFrom(msg.sender, address(this), vars.amount0);
        IERC20(vars.token1).safeTransferFrom(msg.sender, address(this), vars.amount1);

        // get lptokens by adding liquidity then deposit them to the bond
        _depositLiquidity(recipient_, vars);

        // return the remaining tokens to the depositor
        _refund(vars);
    }

    function deposit(
        address recipient_,
        address bond_,
        address[] calldata path_,
        uint256 amount_,
        uint256 amount0Min_,
        uint256 amount1Min_,
        uint256 deadline_,
        uint256 maxPrice_,
        bytes32 referralCode_
    ) external {
        require(recipient_ != address(0), "Recipient cannot be zero");
        require(bond_ != address(0), "Bond cannot be zero");
        require(amount_ > 0, "Amount should be greater than 0");

        DepositVars memory vars;

        vars.bond = bond_;
        vars.amount0Min = amount0Min_;
        vars.amount1Min = amount1Min_;
        vars.deadline = deadline_;
        vars.maxPrice = maxPrice_;
        vars.referralCode = referralCode_;

        vars.lpToken = IGyroBond(vars.bond).tokenIn();
        require(vars.lpToken != address(0), "Bond principle undefined");

        vars.token0 = IUniswapV2Pair(vars.lpToken).token0();
        vars.token1 = IUniswapV2Pair(vars.lpToken).token1();

        uint256 pathLength = path_.length;
        require(pathLength >= 2 && path_[0] != path_[pathLength - 1], "path error");
        require(path_[0] == vars.token0 || path_[0] == vars.token1, "Token error");
        require(path_[pathLength - 1] == vars.token0 || path_[pathLength - 1] == vars.token1, "Token error");

        // save previous balances

        vars.prevToken0Bal = IERC20(vars.token0).balanceOf(address(this));
        vars.prevToken1Bal = IERC20(vars.token1).balanceOf(address(this));

        // get the tokens from the depositor
        IERC20(path_[0]).safeTransferFrom(msg.sender, address(this), amount_);

        // Swap for the other token
        uint256 amountSwap = amount_.div(2);
        IERC20(path_[0]).safeIncreaseAllowance(router, amountSwap);
        IUniswapV2Router02(router).swapExactTokensForTokens(amountSwap, 0, path_, address(this), vars.deadline);

        vars.amount0 = IERC20(vars.token0).balanceOf(address(this)).sub(vars.prevToken0Bal);
        vars.amount1 = IERC20(vars.token1).balanceOf(address(this)).sub(vars.prevToken1Bal);

        // get lptokens by adding liquidity then deposit them to the bond
        _depositLiquidity(recipient_, vars);

        // return the remaining tokens to the depositor
        _refund(vars);
    }

    function _depositLiquidity(address recipient_, DepositVars memory vars_) internal {
        // add liquidity to the router
        IERC20(vars_.token0).safeIncreaseAllowance(router, vars_.amount0);
        IERC20(vars_.token1).safeIncreaseAllowance(router, vars_.amount1);

        (, , uint256 liquidity) =
            IUniswapV2Router02(router).addLiquidity(
                vars_.token0,
                vars_.token1,
                vars_.amount0,
                vars_.amount1,
                vars_.amount0Min,
                vars_.amount1Min,
                address(this),
                vars_.deadline
            );

        // make sure we have enough liquidity to deposit to the bond

        require(liquidity > 0, "Not enough liquidity");

        IERC20(vars_.lpToken).safeIncreaseAllowance(vars_.bond, liquidity);
        IGyroBond(vars_.bond).deposit(liquidity, vars_.maxPrice, recipient_, vars_.referralCode);
    }

    function _refund(DepositVars memory vars_) internal {
        uint256 currToken0Bal = IERC20(vars_.token0).balanceOf(address(this));
        uint256 currToken1Bal = IERC20(vars_.token1).balanceOf(address(this));
        if (currToken0Bal > vars_.prevToken0Bal) {
            IERC20(vars_.token0).safeTransfer(msg.sender, currToken0Bal.sub(vars_.prevToken0Bal));
        }
        if (currToken1Bal > vars_.prevToken1Bal) {
            IERC20(vars_.token1).safeTransfer(msg.sender, currToken1Bal.sub(vars_.prevToken1Bal));
        }
    }

    /**
     *  @notice allow anyone to send lost tokens to the owner
     */
    function recoverLostToken(address token_) external onlyOwner() {
        IERC20(token_).safeTransfer(msg.sender, IERC20(token_).balanceOf(address(this)));
    }
}

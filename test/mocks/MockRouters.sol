// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Router V2 simulado (SaucerSwap V2 / Uniswap V3): out = in * num / den.
contract MockRouterV2 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    uint256 public num = 1;
    uint256 public den = 1;
    bool public ignoreMinOut;

    function setRate(uint256 n, uint256 d) external {
        num = n;
        den = d;
    }

    function setIgnoreMinOut(bool v) external {
        ignoreMinOut = v;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        require(block.timestamp <= p.deadline, "Transaction too old");
        address tin = address(bytes20(p.path[0:20]));
        address tout = address(bytes20(p.path[p.path.length - 20:]));
        IERC20(tin).transferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * num) / den;
        if (!ignoreMinOut) require(out >= p.amountOutMinimum, "Too little received");
        IERC20(tout).transfer(p.recipient, out);
    }
}

/// @notice Router V1 simulado (SaucerSwap V1 / Uniswap V2).
contract MockRouterV1 {
    uint256 public num = 1;
    uint256 public den = 1;

    function setRate(uint256 n, uint256 d) external {
        num = n;
        den = d;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "UniswapV2Router: EXPIRED");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * num) / den;
        require(out >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).transfer(to, out);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }
}

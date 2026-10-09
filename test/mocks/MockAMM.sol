// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Pool de producto constante (x·y=k) con comisión del 0,3 %, como SaucerSwap V1 / Uniswap V2.
///         Las reservas son los saldos reales del pool.
contract MockPair {
    address public immutable tokenA;
    address public immutable tokenB;

    constructor(address a, address b) {
        tokenA = a;
        tokenB = b;
    }

    function other(address t) public view returns (address) {
        require(t == tokenA || t == tokenB, "token");
        return t == tokenA ? tokenB : tokenA;
    }

    function reserveOf(address t) public view returns (uint256) {
        return IERC20(t).balanceOf(address(this));
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        uint256 rIn = reserveOf(tokenIn);
        uint256 rOut = reserveOf(other(tokenIn));
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    function getAmountIn(address tokenOut, uint256 amountOut) public view returns (uint256) {
        uint256 rIn = reserveOf(other(tokenOut));
        uint256 rOut = reserveOf(tokenOut);
        require(amountOut < rOut, "liquidity");
        return (rIn * amountOut * 1000) / ((rOut - amountOut) * 997) + 1;
    }

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        out = getAmountOut(tokenIn, amountIn);
        require(out >= minOut, "slippage");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(other(tokenIn)).transfer(to, out);
    }

    function swapExactOut(address tokenOut, uint256 amountOut, uint256 maxIn, address to)
        external
        returns (uint256 amountIn)
    {
        amountIn = getAmountIn(tokenOut, amountOut);
        require(amountIn <= maxIn, "slippage");
        IERC20(other(tokenOut)).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);
    }
}

/// @notice Router estilo SaucerSwap V1 sobre MockPair (rutas de 2 tokens). Se instala con vm.etch
///         en la dirección del routerV1 del vault; los pares se registran con setPair.
contract PairRouterV1 {
    mapping(bytes32 => address) public pairOf;

    function setPair(address a, address b, address pair) external {
        pairOf[_key(a, b)] = pair;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(path.length == 2, "path");
        MockPair p = MockPair(pairOf[_key(path[0], path[1])]);
        require(address(p) != address(0), "pair");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).approve(address(p), amountIn);
        uint256 out = p.swapExactIn(path[0], amountIn, amountOutMin, to);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}

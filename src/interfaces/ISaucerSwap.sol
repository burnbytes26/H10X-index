// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice SaucerSwap V1 RouterV3 (Uniswap V2 fork). Mainnet 0.0.3045981 · Testnet 0.0.19264
/// @dev Signature as documented at docs.saucerswap.finance (swap tokens for tokens). Requires an HTS allowance to the router.
interface ISaucerSwapV1Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice SaucerSwap V2 SwapRouter (Uniswap V3 fork). Mainnet 0.0.3949434 · Testnet 0.0.1414040
/// @dev path = [token(20) | fee(3) | token(20) | ...]. Requires an HTS allowance to the router.
interface ISaucerSwapV2Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

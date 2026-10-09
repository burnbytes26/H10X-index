// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {HederaTokenService} from "@hiero/token-service/HederaTokenService.sol";
import {IHederaTokenService} from "@hiero/token-service/IHederaTokenService.sol";
import {HederaResponseCodes} from "@hiero/common/HederaResponseCodes.sol";

import {ISaucerSwapV1Router, ISaucerSwapV2Router} from "./interfaces/ISaucerSwap.sol";

/// @title H10XVault
/// @notice Vault of the H10X index. It is the TREASURY and the only SUPPLY KEY of the H10X HTS token, which it either
///         creates itself (`initialize`) or adopts after checking it on-chain (`initializeWithToken`, for a token
///         with a metadata key for its logo). The token has no admin key and no freeze/wipe/kyc/pause/fee keys:
///         nobody can mint outside these rules.
///
///         - issue:   deposit the basket in proportion to what the vault already holds → H10X is minted.
///         - redeem:  burn H10X → receive the proportional share of every component. Never paused.
///         - rebalance: SaucerSwap swaps between components, only by the `rebalancer` role, with limits.
///           A component with target weight 0 (exit decided by the owner) can be sold in full in one swap
///           (`amountIn` is then an upper bound: the swap sells min(amountIn, balance at execution)) and is
///           removed when that swap leaves it at 0.
///
///         Issue and redeem use no oracle: the market price is anchored to the real NAV by arbitrage.
///         Arrays passed to issue/redeem/setTargetWeights are indexed by component position, so callers also pass
///         the `configVersion` they quoted against; any change to the component list or the fees bumps it.
///         Components must have no KYC, freeze, pause or fee-schedule key and no custom fees (on Hedera such keys
///         cannot be added after creation). A component deleted by its issuer can be removed by the owner.
/// @dev    Built for Hedera (HTS via 0x167 + the HIP-218 ERC-20 facade). Not upgradeable.
contract H10XVault is HederaTokenService, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ─────────────────────────── constants ───────────────────────────
    string public constant VERSION = "H10XVault 1.3.0";
    uint256 public constant MAX_COMPONENTS = 10;
    uint256 public constant BPS = 10_000;
    /// @notice Hard fee cap (1%). Not even the owner can exceed it.
    uint16 public constant MAX_FEE_BPS = 100;
    /// @notice The initial seed must issue at least 1 H10X (8 decimals).
    uint256 public constant MIN_SEED_SHARES = 1e8;
    int32 public constant H10X_DECIMALS = 8;
    int64 internal constant AUTO_RENEW_PERIOD = 7_776_000; // 90 days
    uint256 internal constant SUPPLY_KEY_BIT = 16; // bit 4 = supplyKey (IHederaTokenService.TokenKey)
    /// @notice Rebalance `amountIn` with no upper bound: sell the whole balance (only components with target
    ///         weight 0). Off-chain tooling should prefer the planned amount plus a small margin, so the signed
    ///         `minAmountOut` keeps matching the amount actually sold.
    uint256 public constant SELL_ALL = type(uint256).max;

    // ─────────────────────────── immutables ───────────────────────────
    /// @notice SaucerSwap V1 RouterV3 (address(0) = disabled).
    address public immutable routerV1;
    /// @notice SaucerSwap V2 SwapRouter (address(0) = disabled).
    address public immutable routerV2;

    // ─────────────────────────── state ───────────────────────────
    /// @notice The H10X HTS token (long-zero EVM address). Zero until initialized.
    address public h10x;

    address[] internal _components;
    mapping(address => bool) public isComponent;
    /// @notice Target weight (bps). Guides rebalancing; issue and redeem use the actual holdings.
    mapping(address => uint16) public targetWeightBps;

    uint16 public mintFeeBps;
    uint16 public redeemFeeBps;
    /// @notice Fees accrued in (fully backed) H10X, waiting for `claimFees`.
    uint256 public accruedFeeShares;
    address public feeRecipient;

    address public guardian;
    address public rebalancer;
    /// @notice Maximum size of a rebalance swap, in bps of the input token balance.
    uint16 public maxTradeBps;
    /// @notice H10X supply cap (smallest units). 0 = no cap.
    uint256 public supplyCap;
    bool public issuancePaused;
    /// @notice Bumped whenever the component list or the fees change. Position-indexed arguments
    ///         (maxAmountsIn, minAmountsOut, skipMask, weights) are only valid for the version they were built for.
    uint256 public configVersion;

    // ─────────────────────────── events ───────────────────────────
    event Initialized(address indexed token);
    event Seeded(address indexed by, address indexed to, uint256 shares, uint256[] amounts);
    event Issued(address indexed by, address indexed to, uint256 shares, uint256 fee, uint256[] amountsIn);
    event Redeemed(
        address indexed by, address indexed to, uint256 shares, uint256 fee, uint256[] amountsOut, uint256 skipMask
    );
    event Rebalanced(uint8 indexed routerVersion, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event ComponentAdded(address indexed token);
    event ComponentRemoved(address indexed token);
    event TargetWeightsSet(address[] tokens, uint16[] weightsBps);
    event FeesSet(uint16 mintFeeBps, uint16 redeemFeeBps);
    event FeesClaimed(address indexed to, uint256 shares);
    event FeeRecipientSet(address indexed recipient);
    event GuardianSet(address indexed guardian);
    event RebalancerSet(address indexed rebalancer);
    event MaxTradeBpsSet(uint16 bps);
    event SupplyCapSet(uint256 cap);
    event IssuancePausedSet(bool paused);
    event StraySharesBurned(uint256 shares);

    // ─────────────────────────── errors ───────────────────────────
    error HtsError(int64 responseCode);
    error AlreadyInitialized();
    error NotInitialized();
    error AlreadySeeded();
    error NotSeeded();
    error SeedTooSmall();
    error ZeroAmount();
    error ZeroAddress();
    error LengthMismatch();
    error BadComponents();
    error WeightsMustSum10000();
    error TooManyComponents();
    error DuplicateComponent(address token);
    error NotAComponent(address token);
    error ComponentHasCustomFees(address token);
    error ComponentNotEmpty(address token);
    error ComponentHasWeight(address token);
    error ComponentDeleted(address token);
    error ConfigChanged(uint256 expected, uint256 current);
    error LastComponent();
    error IssuanceIsPaused();
    error SupplyCapExceeded();
    error NothingDeposited();
    error SlippageIn(address token, uint256 needed, uint256 max);
    error SlippageOut(address token, uint256 out, uint256 min);
    error TransferAmountMismatch(address token, uint256 expected, uint256 received);
    error FeeTooHigh();
    error InvalidBps();
    error Unauthorized();
    error RouterDisabled();
    error BadPath();
    error TradeTooLarge(uint256 amountIn, uint256 max);
    error MinOutRequired();
    error TradeOverspent(uint256 spent, uint256 amountIn);
    error TradeUnderdelivered(uint256 received, uint256 minOut);
    error RenounceDisabled();
    error Int64Overflow();
    error TokenNotAdoptable(string why);
    error TokenHasForbiddenKey(uint256 keyType);

    // ─────────────────────────── modifiers ───────────────────────────
    modifier onlyRebalancer() {
        if (msg.sender != rebalancer) revert Unauthorized();
        _;
    }

    modifier onlyInitialized() {
        if (h10x == address(0)) revert NotInitialized();
        _;
    }

    // ─────────────────────────── constructor ───────────────────────────
    /// @dev The deployer is the owner (so it always matches the msg.sender that initialize/seed will see, whether an
    ///      ECDSA account with a virtual address or a long-zero ED25519 account). Ownership is then moved in 2 steps.
    constructor(
        address feeRecipient_,
        address guardian_,
        address rebalancer_,
        address routerV1_,
        address routerV2_,
        uint16 mintFeeBps_,
        uint16 redeemFeeBps_,
        uint16 maxTradeBps_
    ) Ownable(msg.sender) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (mintFeeBps_ > MAX_FEE_BPS || redeemFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (maxTradeBps_ == 0 || maxTradeBps_ > BPS) revert InvalidBps();
        routerV1 = routerV1_;
        routerV2 = routerV2_;
        feeRecipient = feeRecipient_;
        guardian = guardian_;
        rebalancer = rebalancer_;
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        maxTradeBps = maxTradeBps_;
    }

    /// @notice Accepts HBAR (e.g. for a future token auto-renewal). HBAR is never part of the basket.
    receive() external payable {}

    // ═══════════════════════════ initialization ═══════════════════════════

    /// @notice Creates the H10X token (treasury and supply key = this contract, no admin key) and sets the basket.
    /// @dev    Send enough HBAR for the token creation fee (forwarded to 0x167).
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata memo_,
        address[] calldata tokens,
        uint16[] calldata weightsBps
    ) external payable onlyOwner nonReentrant {
        if (h10x != address(0)) revert AlreadyInitialized();
        uint256 n = tokens.length;
        if (n == 0 || n != weightsBps.length) revert BadComponents();
        if (n > MAX_COMPONENTS) revert TooManyComponents();

        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0].keyType = SUPPLY_KEY_BIT;
        keys[0].key.contractId = address(this);

        IHederaTokenService.HederaToken memory token;
        token.name = name_;
        token.symbol = symbol_;
        token.treasury = address(this);
        token.memo = memo_;
        token.tokenSupplyType = false; // INFINITE: supply is governed by this contract
        token.freezeDefault = false;
        token.tokenKeys = keys; // SUPPLY only → no admin, freeze, wipe, kyc, pause or fee schedule key
        token.expiry = IHederaTokenService.Expiry({
            second: 0,
            autoRenewAccount: address(this),
            autoRenewPeriod: AUTO_RENEW_PERIOD
        });

        (int64 rc, address tokenAddr) = createFungibleToken(token, 0, H10X_DECIMALS);
        _checkHts(rc);
        h10x = tokenAddr;
        _initBasket(tokens, weightsBps);
        emit Initialized(tokenAddr);
    }

    /// @notice Alternative to `initialize`: adopts an H10X token created outside the contract (HAPI TokenCreate),
    ///         e.g. so that it can have a metadata key (HIP-646/657: logo and metadata), which 0x167 cannot create.
    ///         It enforces on-chain the same guarantees as `initialize`: treasury and only supply key = this
    ///         contract; no admin, kyc, freeze, wipe, fee schedule or pause key; supply 0; 8 decimals; infinite
    ///         supply and no custom fees. The metadata key gives no power over balances or supply.
    function initializeWithToken(address token, address[] calldata tokens, uint16[] calldata weightsBps)
        external
        onlyOwner
        nonReentrant
    {
        if (h10x != address(0)) revert AlreadyInitialized();
        if (token == address(0)) revert ZeroAddress();
        uint256 n = tokens.length;
        if (n == 0 || n != weightsBps.length) revert BadComponents();
        if (n > MAX_COMPONENTS) revert TooManyComponents();
        _checkAdoptable(token);
        h10x = token;
        _initBasket(tokens, weightsBps);
        emit Initialized(token);
    }

    /// @notice First issuance: sets the composition per H10X and the initial NAV. Only while supply is 0.
    function seed(uint256[] calldata amounts, uint256 shares, address to)
        external
        onlyOwner
        onlyInitialized
        nonReentrant
    {
        if (_totalSupply() != 0) revert AlreadySeeded();
        if (shares < MIN_SEED_SHARES) revert SeedTooSmall();
        if (to == address(0)) revert ZeroAddress();
        uint256 n = _components.length;
        if (amounts.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            _pullExact(_components[i], msg.sender, amounts[i]);
        }
        _mintShares(shares);
        IERC20(h10x).safeTransfer(to, shares);
        emit Seeded(msg.sender, to, shares, amounts);
    }

    // ═══════════════════════════ issue and redeem ═══════════════════════════

    /// @notice Issues `shares` H10X against the proportional basket (rounding in the vault's favour).
    /// @param maxAmountsIn Maximum to deposit per component (protects against a rebalance between quote and tx).
    /// @param to H10X recipient (must be associated with the token).
    /// @param expectedConfigVersion `configVersion` the arrays were built for (reverts if the basket or fees changed).
    /// @return sharesOut Net H10X delivered (shares − fee).
    /// @return amountsIn Amount of each component deposited.
    function issue(uint256 shares, uint256[] calldata maxAmountsIn, address to, uint256 expectedConfigVersion)
        external
        onlyInitialized
        nonReentrant
        returns (uint256 sharesOut, uint256[] memory amountsIn)
    {
        _checkConfig(expectedConfigVersion);
        if (issuancePaused) revert IssuanceIsPaused();
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 supply = _totalSupply();
        if (supply == 0) revert NotSeeded();
        if (supplyCap != 0 && supply + shares > supplyCap) revert SupplyCapExceeded();
        uint256 n = _components.length;
        if (maxAmountsIn.length != n) revert LengthMismatch();

        amountsIn = new uint256[](n);
        bool deposited;
        for (uint256 i; i < n; ++i) {
            address t = _components[i];
            uint256 need = Math.mulDiv(IERC20(t).balanceOf(address(this)), shares, supply, Math.Rounding.Ceil);
            if (need > maxAmountsIn[i]) revert SlippageIn(t, need, maxAmountsIn[i]);
            if (need != 0) {
                _pullExact(t, msg.sender, need);
                deposited = true;
            }
            amountsIn[i] = need;
        }
        if (!deposited) revert NothingDeposited();

        uint256 fee = (shares * mintFeeBps) / BPS;
        sharesOut = shares - fee;
        _mintShares(shares);
        accruedFeeShares += fee;
        IERC20(h10x).safeTransfer(to, sharesOut);
        emit Issued(msg.sender, to, shares, fee, amountsIn);
    }

    /// @notice Burns H10X and delivers the proportional share of the basket (rounding in the vault's favour).
    ///         Requires an H10X allowance to this contract. NEVER paused.
    /// @param minAmountsOut Minimum per component (ignored for skipped components).
    /// @param to Basket recipient (must be associated with every component received).
    /// @param skipMask Bit i = 1 → you give up component i (it stays in the vault for the other holders).
    ///        Emergency exit if a basket token is blocked by its issuer. Normal use: 0.
    /// @param expectedConfigVersion `configVersion` the arrays and the mask were built for. `type(uint256).max` skips
    ///        the check, so a holder can always leave whatever governance does; use it only with skipMask = 0,
    ///        because the order of the components may have changed.
    function redeem(
        uint256 shares,
        uint256[] calldata minAmountsOut,
        address to,
        uint256 skipMask,
        uint256 expectedConfigVersion
    ) external onlyInitialized nonReentrant returns (uint256[] memory amountsOut) {
        if (expectedConfigVersion != type(uint256).max) _checkConfig(expectedConfigVersion);
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 n = _components.length;
        if (minAmountsOut.length != n) revert LengthMismatch();

        uint256 supply = _totalSupply();
        _pullExact(h10x, msg.sender, shares);
        uint256 fee = (shares * redeemFeeBps) / BPS;
        uint256 net = shares - fee;

        amountsOut = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(incorrect-shift)
            if (skipMask & (1 << i) != 0) continue; // bit i of the mask
            address t = _components[i];
            uint256 out = Math.mulDiv(IERC20(t).balanceOf(address(this)), net, supply);
            if (out < minAmountsOut[i]) revert SlippageOut(t, out, minAmountsOut[i]);
            amountsOut[i] = out;
        }

        _burnShares(net);
        accruedFeeShares += fee;
        for (uint256 i; i < n; ++i) {
            if (amountsOut[i] != 0) IERC20(_components[i]).safeTransfer(to, amountsOut[i]);
        }
        emit Redeemed(msg.sender, to, shares, fee, amountsOut, skipMask);
    }

    /// @notice Sends the accrued fees (in backed H10X) to the feeRecipient. Anyone can call it.
    function claimFees() external nonReentrant returns (uint256 shares) {
        shares = accruedFeeShares;
        if (shares == 0) revert ZeroAmount();
        accruedFeeShares = 0;
        IERC20(h10x).safeTransfer(feeRecipient, shares);
        emit FeesClaimed(feeRecipient, shares);
    }

    /// @notice Burns H10X sent to the vault by mistake (not the fees). Raises everyone's backing.
    function burnStrayShares() external onlyInitialized nonReentrant returns (uint256 stray) {
        stray = IERC20(h10x).balanceOf(address(this)) - accruedFeeShares;
        if (stray == 0) revert ZeroAmount();
        _burnShares(stray);
        emit StraySharesBurned(stray);
    }

    // ═══════════════════════════ rebalancing ═══════════════════════════

    /// @notice Swap between two components through SaucerSwap V2 (exactInput). `rebalancer` only.
    /// @param path [tokenIn|fee|...|tokenOut]; both ends must be components.
    function rebalanceV2(bytes calldata path, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        onlyRebalancer
        nonReentrant
        returns (uint256 amountOut)
    {
        if (routerV2 == address(0)) revert RouterDisabled();
        uint256 len = path.length;
        if (len < 43 || (len - 20) % 23 != 0) revert BadPath();
        address tokenIn = address(bytes20(path[0:20]));
        address tokenOut = address(bytes20(path[len - 20:len]));
        uint256 inBefore;
        uint256 outBefore;
        (inBefore, outBefore, amountIn) = _preTrade(tokenIn, tokenOut, amountIn, minAmountOut);

        IERC20(tokenIn).forceApprove(routerV2, amountIn);
        ISaucerSwapV2Router(routerV2).exactInput(
            ISaucerSwapV2Router.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        );
        IERC20(tokenIn).forceApprove(routerV2, 0);

        amountOut = _postTrade(tokenIn, tokenOut, inBefore, outBefore, amountIn, minAmountOut);
        emit Rebalanced(2, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice Swap between two components through SaucerSwap V1 (swapExactTokensForTokens). `rebalancer` only.
    function rebalanceV1(address[] calldata path, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        onlyRebalancer
        nonReentrant
        returns (uint256 amountOut)
    {
        if (routerV1 == address(0)) revert RouterDisabled();
        if (path.length < 2) revert BadPath();
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 inBefore;
        uint256 outBefore;
        (inBefore, outBefore, amountIn) = _preTrade(tokenIn, tokenOut, amountIn, minAmountOut);

        IERC20(tokenIn).forceApprove(routerV1, amountIn);
        ISaucerSwapV1Router(routerV1).swapExactTokensForTokens(amountIn, minAmountOut, path, address(this), deadline);
        IERC20(tokenIn).forceApprove(routerV1, 0);

        amountOut = _postTrade(tokenIn, tokenOut, inBefore, outBefore, amountIn, minAmountOut);
        emit Rebalanced(1, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ═══════════════════════════ governance ═══════════════════════════

    /// @notice Adds a component (with no balance; rebalancing buys it afterwards) and sets the new target weights in
    ///         the same call (`weightsBps` has one more entry, for the new component, at the end). A new component
    ///         therefore never sits at weight 0, which would mean "exit decided".
    function addComponent(address token, uint16[] calldata weightsBps, uint256 expectedConfigVersion)
        external
        onlyOwner
        onlyInitialized
    {
        _checkConfig(expectedConfigVersion);
        _addComponent(token);
        _setTargetWeights(weightsBps);
        if (weightsBps[weightsBps.length - 1] == 0) revert InvalidBps();
    }

    /// @notice Removes a component whose target weight is 0 and whose balance is 0. With a balance, sell it by
    ///         rebalancing instead: the swap that empties it removes it in the same transaction, leaving no gap for
    ///         donations. A component DELETED by its issuer can no longer be transferred, so it is removed even with
    ///         a balance (that balance is worthless and stays stranded); a deleted token can never be re-added.
    function removeComponent(address token) external onlyOwner {
        if (!isComponent[token]) revert NotAComponent(token);
        if (targetWeightBps[token] != 0) revert ComponentHasWeight(token);
        if (!_isDeleted(token) && IERC20(token).balanceOf(address(this)) != 0) revert ComponentNotEmpty(token);
        _removeComponent(token);
    }

    /// @notice Target weights in the order of `components()` for `expectedConfigVersion`. Must add up to 10000.
    function setTargetWeights(uint16[] calldata weightsBps, uint256 expectedConfigVersion) external onlyOwner {
        _checkConfig(expectedConfigVersion);
        _setTargetWeights(weightsBps);
    }

    function setFees(uint16 mintFeeBps_, uint16 redeemFeeBps_) external onlyOwner {
        if (mintFeeBps_ > MAX_FEE_BPS || redeemFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (mintFeeBps_ != mintFeeBps || redeemFeeBps_ != redeemFeeBps) ++configVersion; // a no-op does not bump
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        emit FeesSet(mintFeeBps_, redeemFeeBps_);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setRebalancer(address rebalancer_) external onlyOwner {
        rebalancer = rebalancer_;
        emit RebalancerSet(rebalancer_);
    }

    function setMaxTradeBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS) revert InvalidBps();
        maxTradeBps = bps;
        emit MaxTradeBpsSet(bps);
    }

    function setSupplyCap(uint256 cap) external onlyOwner {
        supplyCap = cap;
        emit SupplyCapSet(cap);
    }

    /// @notice Pauses issuance ONLY. Owner or guardian. Redemptions stay open.
    function pauseIssuance() external {
        if (msg.sender != owner() && msg.sender != guardian) revert Unauthorized();
        issuancePaused = true;
        emit IssuancePausedSet(true);
    }

    function unpauseIssuance() external onlyOwner {
        issuancePaused = false;
        emit IssuancePausedSet(false);
    }

    /// @notice Disabled, so the vault can never be left without governance by accident.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═══════════════════════════ views ═══════════════════════════

    function components() external view returns (address[] memory) {
        return _components;
    }

    /// @notice Current basket: tokens, target weights and balances held.
    function getBasket()
        external
        view
        returns (address[] memory tokens, uint16[] memory weightsBps, uint256[] memory balances)
    {
        uint256 n = _components.length;
        tokens = _components;
        weightsBps = new uint16[](n);
        balances = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            weightsBps[i] = targetWeightBps[tokens[i]];
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    function totalSupply() external view returns (uint256) {
        return h10x == address(0) ? 0 : _totalSupply();
    }

    /// @notice Amounts to deposit to issue `shares`, and the net H10X received.
    function quoteIssue(uint256 shares) external view returns (uint256[] memory amountsIn, uint256 sharesOut) {
        uint256 supply = h10x == address(0) ? 0 : _totalSupply();
        if (supply == 0) revert NotSeeded();
        uint256 n = _components.length;
        amountsIn = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amountsIn[i] =
                Math.mulDiv(IERC20(_components[i]).balanceOf(address(this)), shares, supply, Math.Rounding.Ceil);
        }
        sharesOut = shares - (shares * mintFeeBps) / BPS;
    }

    /// @notice Basket received when redeeming `shares` (after the fee).
    function quoteRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        uint256 supply = h10x == address(0) ? 0 : _totalSupply();
        if (supply == 0) revert NotSeeded();
        uint256 net = shares - (shares * redeemFeeBps) / BPS;
        uint256 n = _components.length;
        amountsOut = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amountsOut[i] = Math.mulDiv(IERC20(_components[i]).balanceOf(address(this)), net, supply);
        }
    }

    /// @notice Backing of 1 H10X (1e8 units) in the smallest units of each component.
    function backingPerShare() external view returns (uint256[] memory perShare) {
        uint256 supply = h10x == address(0) ? 0 : _totalSupply();
        uint256 n = _components.length;
        perShare = new uint256[](n);
        if (supply == 0) return perShare;
        for (uint256 i; i < n; ++i) {
            perShare[i] = Math.mulDiv(IERC20(_components[i]).balanceOf(address(this)), 1e8, supply);
        }
    }

    // ═══════════════════════════ internal ═══════════════════════════

    function _totalSupply() internal view returns (uint256) {
        return IERC20(h10x).totalSupply();
    }

    function _initBasket(address[] calldata tokens, uint16[] calldata weightsBps) internal {
        for (uint256 i; i < tokens.length; ++i) {
            _addComponent(tokens[i]);
        }
        _setTargetWeights(weightsBps);
    }

    /// @dev Requirements for an H10X token created elsewhere (see `initializeWithToken`). `getTokenKey` returns
    ///      KEY_NOT_PROVIDED only when the key does not exist; any key that is present (including a KeyList or a
    ///      threshold key) returns SUCCESS, so no forbidden key can slip through by not fitting in a KeyValue.
    function _checkAdoptable(address token) internal {
        IHederaTokenService.FungibleTokenInfo memory info = _fungibleInfo(token);
        IHederaTokenService.TokenInfo memory t = info.tokenInfo;
        if (t.token.treasury != address(this)) revert TokenNotAdoptable("treasury");
        if (t.totalSupply != 0) revert TokenNotAdoptable("supply");
        if (info.decimals != H10X_DECIMALS) revert TokenNotAdoptable("decimals");
        if (t.deleted || t.pauseStatus) revert TokenNotAdoptable("deleted/paused");
        if (t.token.tokenSupplyType) revert TokenNotAdoptable("finite supply");
        if (t.token.freezeDefault) revert TokenNotAdoptable("freeze default");
        if (_hasCustomFees(t)) revert TokenNotAdoptable("custom fees");
        // admin 1, kyc 2, freeze 4, wipe 8, fee schedule 32, pause 64 → must not exist
        _requireNoKeys(token, 1 | 2 | 4 | 8 | 32 | 64);
        (int64 src, IHederaTokenService.KeyValue memory sk) = getTokenKey(token, SUPPLY_KEY_BIT);
        if (
            src != HederaResponseCodes.SUCCESS || sk.contractId != address(this) || sk.inheritAccountKey
                || sk.ed25519.length != 0 || sk.ECDSA_secp256k1.length != 0 || sk.delegatableContractId != address(0)
        ) revert TokenNotAdoptable("supply key");
    }

    function _addComponent(address token) internal {
        if (token == address(0) || token == h10x) revert BadComponents();
        if (isComponent[token]) revert DuplicateComponent(token);
        if (_components.length >= MAX_COMPONENTS) revert TooManyComponents();

        // Admission rules. A deleted token cannot move. Custom fees would break the proportional accounting (or be
        // charged to the vault on every payout). A KYC, freeze or pause key would let its issuer block the vault's
        // transfers, and a fee-schedule key would let it add fees later. On Hedera a key that a token was created
        // without can never be added, so these checks hold for the component's whole life.
        IHederaTokenService.TokenInfo memory t = _fungibleInfo(token).tokenInfo;
        if (t.deleted) revert ComponentDeleted(token);
        if (_hasCustomFees(t)) revert ComponentHasCustomFees(token);
        // kyc 2, freeze 4, fee schedule 32, pause 64 → must not exist (admin, wipe, supply and metadata are allowed)
        _requireNoKeys(token, 2 | 4 | 32 | 64);

        int64 rc = associateToken(address(this), token);
        if (rc != HederaResponseCodes.SUCCESS && rc != HederaResponseCodes.TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT) {
            revert HtsError(rc);
        }

        _components.push(token);
        isComponent[token] = true;
        ++configVersion;
        emit ComponentAdded(token);
    }

    function _removeComponent(address token) internal {
        uint256 n = _components.length;
        if (n == 1) revert LastComponent();
        for (uint256 i; i < n; ++i) {
            if (_components[i] == token) {
                _components[i] = _components[n - 1];
                _components.pop();
                break;
            }
        }
        isComponent[token] = false;
        delete targetWeightBps[token];
        ++configVersion;
        emit ComponentRemoved(token);
    }

    function _setTargetWeights(uint16[] calldata weightsBps) internal {
        uint256 n = _components.length;
        if (weightsBps.length != n) revert LengthMismatch();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            targetWeightBps[_components[i]] = weightsBps[i];
            sum += weightsBps[i];
        }
        if (sum != BPS) revert WeightsMustSum10000();
        emit TargetWeightsSet(_components, weightsBps);
    }

    /// @dev Pulls `amount` from `from` and requires it to arrive exactly (rejects fee-on-transfer tokens).
    function _pullExact(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert TransferAmountMismatch(token, amount, received);
    }

    function _mintShares(uint256 amount) internal {
        (int64 rc,,) = mintToken(h10x, _toInt64(amount), new bytes[](0));
        _checkHts(rc);
    }

    function _burnShares(uint256 amount) internal {
        (int64 rc,) = burnToken(h10x, _toInt64(amount), new int64[](0));
        _checkHts(rc);
    }

    function _preTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (uint256 inBefore, uint256 outBefore, uint256 amount)
    {
        if (!isComponent[tokenIn]) revert NotAComponent(tokenIn);
        if (!isComponent[tokenOut]) revert NotAComponent(tokenOut);
        if (tokenIn == tokenOut) revert BadPath();
        if (minAmountOut == 0) revert MinOutRequired();
        inBefore = IERC20(tokenIn).balanceOf(address(this));
        // Target weight 0 = the owner has decided its exit: no per-swap cap, and `amountIn` is an upper bound, so the
        // swap sells min(amountIn, balance at execution). A small donation within that bound is sold too (and the
        // component still leaves atomically), while a balance that grew beyond the signed amount is not sold under
        // a `minAmountOut` that was computed for less.
        bool exiting = targetWeightBps[tokenIn] == 0;
        amount = exiting && amountIn >= inBefore ? inBefore : amountIn;
        if (amount == 0) revert ZeroAmount();
        if (!exiting) {
            uint256 maxIn = (inBefore * maxTradeBps) / BPS;
            if (amount > maxIn) revert TradeTooLarge(amount, maxIn);
        }
        outBefore = IERC20(tokenOut).balanceOf(address(this));
    }

    /// @dev Checks the swap and, if the sold component has weight 0 and is now empty, removes it from the basket.
    function _postTrade(
        address tokenIn,
        address tokenOut,
        uint256 inBefore,
        uint256 outBefore,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 spent = inBefore - inAfter;
        if (spent > amountIn) revert TradeOverspent(spent, amountIn);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minAmountOut) revert TradeUnderdelivered(amountOut, minAmountOut);
        if (inAfter == 0 && targetWeightBps[tokenIn] == 0) _removeComponent(tokenIn);
    }

    function _checkConfig(uint256 expected) internal view {
        if (expected != configVersion) revert ConfigChanged(expected, configVersion);
    }

    function _fungibleInfo(address token) internal returns (IHederaTokenService.FungibleTokenInfo memory info) {
        int256 rc;
        (rc, info) = getFungibleTokenInfo(token);
        // casting to int64 is safe: the library decodes the response code as an int32
        // forge-lint: disable-next-line(unsafe-typecast)
        if (rc != HederaResponseCodes.SUCCESS) revert HtsError(int64(rc));
    }

    function _hasCustomFees(IHederaTokenService.TokenInfo memory t) internal pure returns (bool) {
        return t.fixedFees.length != 0 || t.fractionalFees.length != 0 || t.royaltyFees.length != 0;
    }

    /// @dev Reverts unless every key type in `mask` is absent. `getTokenKey` returns KEY_NOT_PROVIDED only when the
    ///      key does not exist; any key that is present (including a KeyList or a threshold key) returns SUCCESS.
    function _requireNoKeys(address token, uint256 mask) internal {
        for (uint256 k = 1; k <= 64; k <<= 1) {
            if (mask & k == 0) continue;
            (int64 krc,) = getTokenKey(token, k);
            if (krc != HederaResponseCodes.KEY_NOT_PROVIDED) revert TokenHasForbiddenKey(k);
        }
    }

    /// @dev True only if HTS reports the token as deleted. Any failure counts as "not deleted" (fails closed).
    function _isDeleted(address token) internal returns (bool) {
        (int256 rc, IHederaTokenService.FungibleTokenInfo memory info) = getFungibleTokenInfo(token);
        return rc == HederaResponseCodes.SUCCESS && info.tokenInfo.deleted;
    }

    function _checkHts(int64 rc) internal pure {
        if (rc != HederaResponseCodes.SUCCESS) revert HtsError(rc);
    }

    function _toInt64(uint256 x) internal pure returns (int64) {
        if (x > uint256(uint64(type(int64).max))) revert Int64Overflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return int64(uint64(x)); // safe: bounded by the previous line
    }
}

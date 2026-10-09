// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHederaTokenService} from "@hiero/token-service/IHederaTokenService.sol";

import {H10XVault} from "../src/H10XVault.sol";
import {MockHTS} from "./mocks/MockHTS.sol";
import {MockRouterV1, MockRouterV2} from "./mocks/MockRouters.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice Montaje común: HTS simulado en 0x167, 3 componentes con decimales distintos, bóveda inicializada.
abstract contract BaseVaultTest is Test {
    MockHTS internal hts = MockHTS(address(0x167));
    H10XVault internal vault;
    MockRouterV1 internal r1;
    MockRouterV2 internal r2;
    address internal h10x;

    address internal owner = makeAddr("owner");
    address internal feeRec = makeAddr("feeRecipient");
    address internal guardian = makeAddr("guardian");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address[] internal comps;
    uint16[] internal weights;

    uint16 internal constant FEE_BPS = 50; // 0,5 %
    uint256 internal constant SEED_SHARES = 1_000e8; // 1.000 H10X

    function setUp() public virtual {
        vm.etch(address(0x167), address(new MockHTS()).code);

        // Componentes: tipo WHBAR (8 dec), tipo SAUCE (6 dec), tipo DOVU (8 dec)
        comps.push(_createToken("Wrapped HBAR", "tWHBAR", 8, 1e18));
        comps.push(_createToken("Sauce", "tSAUCE", 6, 1e18));
        comps.push(_createToken("Dovu", "tDOVU", 8, 1e18));
        weights.push(5000);
        weights.push(3000);
        weights.push(2000);

        r1 = new MockRouterV1();
        r2 = new MockRouterV2();
        vm.prank(owner);
        vault = new H10XVault(feeRec, guardian, rebalancer, address(r1), address(r2), FEE_BPS, FEE_BPS, 2000);

        vm.deal(owner, 1_000 ether);
        vm.prank(owner);
        vault.initialize{value: 20 ether}("H10X Index", "H10X", "H10X test", comps, weights);
        h10x = vault.h10x();

        address[5] memory users = [owner, alice, bob, feeRec, address(r1)];
        for (uint256 u; u < users.length; ++u) {
            _assocAll(users[u]);
        }
        _assocAll(address(r2));

        // Liquidez para los routers simulados y saldos de usuarios
        for (uint256 i; i < comps.length; ++i) {
            IERC20(comps[i]).transfer(address(r1), 1e16);
            IERC20(comps[i]).transfer(address(r2), 1e16);
            IERC20(comps[i]).transfer(owner, 1e16);
            IERC20(comps[i]).transfer(alice, 1e16);
            IERC20(comps[i]).transfer(bob, 1e16);
        }

        _seed();
    }

    // ───────────── helpers ─────────────

    function _createToken(string memory name, string memory symbol, uint8 dec, uint256 supply)
        internal
        returns (address token)
    {
        IHederaTokenService.HederaToken memory t;
        t.name = name;
        t.symbol = symbol;
        t.treasury = address(this);
        t.memo = "";
        t.expiry.autoRenewPeriod = 7_776_000;
        int64 rc;
        (rc, token) = hts.createFungibleToken{value: 1}(t, int64(uint64(supply)), int32(uint32(dec)));
        require(rc == 22, "create failed");
    }

    function _assoc(address account, address token) internal {
        vm.prank(account);
        hts.associateToken(account, token);
    }

    function _assocAll(address account) internal {
        for (uint256 i; i < comps.length; ++i) {
            if (!hts.isAssociated(comps[i], account)) _assoc(account, comps[i]);
        }
        if (h10x != address(0) && !hts.isAssociated(h10x, account)) _assoc(account, h10x);
    }

    function _approveAll(address user) internal {
        vm.startPrank(user);
        for (uint256 i; i < comps.length; ++i) {
            IERC20(comps[i]).approve(address(vault), type(uint256).max);
        }
        IERC20(h10x).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Seed: 1.000 H10X respaldados por 5.000 tWHBAR, 30.000 tSAUCE y 2.000.000 tDOVU.
    function _seed() internal {
        _approveAll(owner);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e8;
        amounts[1] = 30_000e6;
        amounts[2] = 2_000_000e8;
        vm.prank(owner);
        vault.seed(amounts, SEED_SHARES, owner);
    }

    function _maxIn() internal view returns (uint256[] memory m) {
        m = new uint256[](comps.length);
        for (uint256 i; i < m.length; ++i) {
            m[i] = type(uint256).max;
        }
    }

    function _zeros() internal view returns (uint256[] memory z) {
        z = new uint256[](comps.length);
    }

    function _vaultBal(uint256 i) internal view returns (uint256) {
        return IERC20(comps[i]).balanceOf(address(vault));
    }

    function _v2Path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(3000), b);
    }

    /// @dev Weights for adding one component to `v`: current weights with 1 % moved from the heaviest to the new one.
    ///      View calls: build them BEFORE a vm.prank.
    function _weightsPlusOne(H10XVault v) internal view returns (uint16[] memory w) {
        address[] memory c = v.components();
        w = new uint16[](c.length + 1);
        uint256 heaviest;
        for (uint256 i; i < c.length; ++i) {
            w[i] = v.targetWeightBps(c[i]);
            if (w[i] > w[heaviest]) heaviest = i;
        }
        w[heaviest] -= 100;
        w[c.length] = 100;
    }

    /// @dev Owner adds `token` to the main vault with `_weightsPlusOne`.
    function _addComp(address token) internal {
        uint16[] memory w = _weightsPlusOne(vault);
        uint256 cv = CfgVersion.get(address(vault));
        vm.prank(owner);
        vault.addComponent(token, w, cv);
    }
}

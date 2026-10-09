// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseVaultTest} from "./BaseVaultTest.sol";
import {H10XVault} from "../src/H10XVault.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice Actor que emite, reembolsa, reclama comisiones y quema H10X perdidos al azar.
///         Tras cada acción comprueba que el respaldo por H10X de cada componente no baja.
contract VaultHandler is Test {
    H10XVault internal vault;
    address internal h10x;
    address[] internal comps;
    address[] internal actors;

    uint256[] internal lastBacking;
    uint256 public violations;
    uint256 public issues;
    uint256 public redeems;

    constructor(H10XVault vault_, address[] memory comps_, address[] memory actors_) {
        vault = vault_;
        h10x = vault_.h10x();
        comps = comps_;
        actors = actors_;
        lastBacking = _backing();
    }

    function issue(uint256 actorSeed, uint256 shares) external {
        address a = actors[actorSeed % actors.length];
        uint256 supply = vault.totalSupply();
        if (supply == 0) return; // tras quemar todo el supply hace falta un nuevo seed del owner
        shares = bound(shares, 1, supply);
        (uint256[] memory need,) = vault.quoteIssue(shares);
        for (uint256 i; i < comps.length; ++i) {
            if (IERC20(comps[i]).balanceOf(a) < need[i]) return;
        }
        vm.prank(a);
        vault.issue(shares, need, a, CfgVersion.get(address(vault)));
        issues++;
        _check();
    }

    function redeem(uint256 actorSeed, uint256 shares, uint256 skipMask) external {
        address a = actors[actorSeed % actors.length];
        uint256 bal = IERC20(h10x).balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        // 1 de cada 8 reembolsos renuncia a algún componente
        skipMask = skipMask % 8 == 0 ? (skipMask >> 3) & 7 : 0;
        vm.prank(a);
        vault.redeem(shares, new uint256[](comps.length), a, skipMask, CfgVersion.get(address(vault)));
        redeems++;
        _check();
    }

    function claimFees() external {
        if (vault.accruedFeeShares() == 0) return;
        vault.claimFees();
        _check();
    }

    function donateAndBurnStray(uint256 actorSeed, uint256 shares) external {
        address a = actors[actorSeed % actors.length];
        uint256 bal = IERC20(h10x).balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        IERC20(h10x).transfer(address(vault), shares);
        vault.burnStrayShares();
        _check();
    }

    function _backing() internal view returns (uint256[] memory per) {
        uint256 supply = vault.totalSupply();
        per = new uint256[](comps.length);
        if (supply == 0) return per;
        for (uint256 i; i < comps.length; ++i) {
            per[i] = (IERC20(comps[i]).balanceOf(address(vault)) * 1e18) / supply;
        }
    }

    function _check() internal {
        uint256[] memory nowB = _backing();
        // Con supply 0 (alguien donó todos los H10X y se quemaron) el respaldo por H10X no está definido.
        if (vault.totalSupply() != 0) {
            for (uint256 i; i < nowB.length; ++i) {
                if (nowB[i] < lastBacking[i]) violations++;
            }
        }
        lastBacking = nowB;
    }
}

contract H10XVaultInvariantTest is BaseVaultTest {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = owner;
        actors[1] = alice;
        actors[2] = bob;
        _approveAll(alice);
        _approveAll(bob);
        handler = new VaultHandler(vault, comps, actors);
        targetContract(address(handler));
    }

    /// El respaldo por H10X de cada componente nunca baja con emisiones, reembolsos, comisiones ni donaciones.
    function invariant_backingPerShareNeverDecreases() public view {
        assertEq(handler.violations(), 0);
    }

    /// Todo el supply es reembolsable con lo que custodia la bóveda.
    function invariant_supplyFullyBacked() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        uint256[] memory q = vault.quoteRedeem(supply);
        for (uint256 i; i < comps.length; ++i) {
            assertLe(q[i], IERC20(comps[i]).balanceOf(address(vault)));
        }
    }

    /// Las comisiones acumuladas siempre están físicamente en la bóveda.
    function invariant_accruedFeesHeldByVault() public view {
        assertGe(IERC20(h10x).balanceOf(address(vault)), vault.accruedFeeShares());
    }
}

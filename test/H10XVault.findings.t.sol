// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {H10XVault} from "../src/H10XVault.sol";
import {BaseVaultTest} from "./BaseVaultTest.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice Hallazgo M-1 de la revisión del 30-sep-2026 y su arreglo (H10XVault 1.2.0).
///         Antes: cualquiera podía bloquear removeComponent donando 1 unidad del componente tras venderlo.
///         Ahora: con peso objetivo 0, el rebalanceo vende TODO el saldo (SELL_ALL, medido al ejecutar) y el mismo
///         swap retira el componente, sin hueco entre venta y retirada.
contract H10XVaultFindingsTest is BaseVaultTest {
    uint256 internal constant ALL = type(uint256).max;

    event ComponentRemoved(address indexed token);

    /// Pone a 0 el peso de tDOVU (comps[2]) y reparte el resto.
    function _exitDovu() internal {
        uint16[] memory w = new uint16[](3);
        w[0] = 7000;
        w[1] = 3000;
        w[2] = 0;
        vm.prank(owner);
        vault.setTargetWeights(w, CfgVersion.get(address(vault)));
    }

    function _v1Path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function test_version() public view {
        assertEq(vault.VERSION(), "H10XVault 1.3.0");
        assertEq(vault.SELL_ALL(), ALL);
    }

    /// El ataque de antes ya no funciona: la donación se vende junto con el resto y el componente sale en el mismo swap.
    function test_fix_donationIsSoldAndComponentRemovedAtomically() public {
        _exitDovu();
        vm.prank(bob);
        IERC20(comps[2]).transfer(address(vault), 1); // el "ataque": 1 unidad donada
        uint256 bal = _vaultBal(2);
        r2.setRate(1, 400);

        vm.expectEmit(true, false, false, false, address(vault));
        emit ComponentRemoved(comps[2]);
        vm.prank(rebalancer);
        uint256 got = vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);

        assertEq(got, bal / 400);
        assertEq(_vaultBal(2), 0);
        assertFalse(vault.isComponent(comps[2]));
        assertEq(vault.components().length, 2);
        assertEq(vault.targetWeightBps(comps[2]), 0);
        assertEq(IERC20(comps[2]).allowance(address(vault), address(r2)), 0);
    }

    function test_fix_sellAllV1_alsoRemoves() public {
        _exitDovu();
        r1.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV1(_v1Path(comps[2], comps[0]), ALL, 1, block.timestamp);
        assertFalse(vault.isComponent(comps[2]));
        assertEq(IERC20(comps[2]).allowance(address(vault), address(r1)), 0);
    }

    /// Una donación DESPUÉS de la retirada ya no afecta: el token no es componente.
    function test_fix_donationAfterRemovalIsHarmless() public {
        _exitDovu();
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);
        vm.prank(bob);
        IERC20(comps[2]).transfer(address(vault), 1);
        assertFalse(vault.isComponent(comps[2]));

        // emisión y reembolso siguen con los 2 componentes restantes
        _approveAll(alice);
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;
        vm.prank(alice);
        vault.issue(1e8, maxIn, alice, CfgVersion.get(address(vault)));
        vm.prank(alice);
        vault.redeem(1e8 / 2, new uint256[](2), alice, 0, CfgVersion.get(address(vault)));
    }

    /// Peso 0: sin tope por swap aunque maxTradeBps sea 20 %.
    function test_fix_zeroWeight_ignoresTradeCap() public {
        _exitDovu();
        uint256 bal = _vaultBal(2);
        uint256 half = bal / 2; // 50 % > tope del 20 %
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), half, 1, block.timestamp);
        assertTrue(vault.isComponent(comps[2])); // venta parcial: sigue en la cesta
        assertEq(_vaultBal(2), bal - half);
    }

    /// Venta exacta de todo el saldo (sin SELL_ALL) también retira si el peso es 0.
    function test_fix_exactFullAmount_alsoRemoves() public {
        _exitDovu();
        uint256 bal = _vaultBal(2);
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), bal, 1, block.timestamp);
        assertFalse(vault.isComponent(comps[2]));
    }

    /// Con peso > 0 nada cambia: SELL_ALL no está permitido y el tope por swap sigue.
    function test_fix_nonZeroWeight_keepsCap_andRejectsSellAll() public {
        uint256 maxIn = (_vaultBal(2) * 2000) / 10_000;
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TradeTooLarge.selector, ALL, maxIn));
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);

        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TradeTooLarge.selector, maxIn + 1, maxIn));
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), maxIn + 1, 1, block.timestamp);
    }

    /// Vender todo un componente con peso > 0 (tope al 100 %) NO lo retira: solo sale lo que el owner ha puesto a 0.
    function test_fix_nonZeroWeight_emptiedButNotRemoved() public {
        vm.prank(owner);
        vault.setMaxTradeBps(10_000);
        uint256 bal = _vaultBal(2);
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), bal, 1, block.timestamp);
        assertEq(_vaultBal(2), 0);
        assertTrue(vault.isComponent(comps[2]));
    }

    /// El precio mínimo sigue siendo obligatorio también en la venta total.
    function test_fix_sellAll_requiresMinOut() public {
        _exitDovu();
        vm.prank(rebalancer);
        vm.expectRevert(H10XVault.MinOutRequired.selector);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 0, block.timestamp);
    }

    /// Y si el pool paga menos del mínimo, revierte entero: ni se vende ni se retira.
    function test_fix_sellAll_underdeliveredReverts() public {
        _exitDovu();
        uint256 bal = _vaultBal(2);
        r2.setRate(1, 400);
        r2.setIgnoreMinOut(true);
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TradeUnderdelivered.selector, bal / 400, bal / 400 + 1));
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, bal / 400 + 1, block.timestamp);
        assertTrue(vault.isComponent(comps[2]));
        assertEq(_vaultBal(2), bal);
    }

    /// SELL_ALL de un componente con peso 0 y saldo 0 → ZeroAmount (para eso está removeComponent).
    function test_fix_sellAll_emptyReverts_thenOwnerRemoves() public {
        _exitDovu();
        r2.setRate(1, 400);
        uint256 half = _vaultBal(2) / 2; // leer antes del prank (la lectura lo consumiría)
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), half, 1, block.timestamp);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp); // retira
        assertFalse(vault.isComponent(comps[2]));
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.NotAComponent.selector, comps[2]));
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);
    }

    /// Solo el rebalancer puede lanzar la venta total.
    function test_fix_sellAll_onlyRebalancer() public {
        _exitDovu();
        vm.prank(owner);
        vm.expectRevert(H10XVault.Unauthorized.selector);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);
    }

    /// removeComponent del owner sigue exigiendo saldo 0 (un componente sin fondos se quita directamente).
    function test_removeComponent_ownerStillRequiresEmpty() public {
        _exitDovu();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(H10XVault.ComponentNotEmpty.selector, comps[2]));
        vault.removeComponent(comps[2]);
    }

    /// Fuzz: con peso 0 y cualquier donación previa, SELL_ALL deja el saldo a 0 y retira el componente.
    function testFuzz_fix_anyDonationIsSold(uint96 donation) public {
        donation = uint96(bound(donation, 0, 1e15));
        _exitDovu();
        if (donation > 0) {
            vm.prank(bob);
            IERC20(comps[2]).transfer(address(vault), donation);
        }
        r2.setRate(1, 400);
        vm.prank(rebalancer);
        vault.rebalanceV2(_v2Path(comps[2], comps[0]), ALL, 1, block.timestamp);
        assertEq(_vaultBal(2), 0);
        assertFalse(vault.isComponent(comps[2]));
    }
}

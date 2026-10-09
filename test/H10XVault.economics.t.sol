// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseVaultTest} from "./BaseVaultTest.sol";
import {MockPair, PairRouterV1} from "./mocks/MockAMM.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice Simulación económica: ¿el precio de mercado de H10X vuelve al NAV y nadie gana a costa de los holders?
///
/// Mundo simulado (unidades de 8 decimales salvo SAUCE, 6):
///   - Cesta por H10X: 5 W + 30 SAUCE + 2.000 DOVU. Precios justos: SAUCE 0,1 W · DOVU 0,001 W → NAV = 10 W (50/30/20 %).
///   - Pool H10X/W: 100 H10X / 1.000 W (precio inicial = NAV).
///   - Pools de componentes líquidos (1 M W de profundidad) e ilíquidos (10 k W).
///   - Actores: ballena, arbitrajista (con cesta en inventario o solo con W) y atacante.
///   Todo se valora a precios justos (mercado externo), no al precio del pool que se manipula.
contract H10XEconomicsTest is BaseVaultTest {
    address internal W;
    address internal S;
    address internal D;

    MockPair internal hPool;
    MockPair internal sLiq;
    MockPair internal dLiq;
    MockPair internal sIll;
    MockPair internal dIll;

    address internal whale = makeAddr("whale");
    address internal arb = makeAddr("arb");
    address internal attacker = makeAddr("attacker");

    uint256[3] internal pNum; // precio justo en W por unidad = pNum / pDen
    uint256[3] internal pDen;

    /// Banda teórica con inventario: ±(1/(0,995·0,997) − 1) ≈ ±80,7 pb. Margen por granularidad y redondeos.
    int256 internal constant BAND_BPS = 85;

    function setUp() public override {
        super.setUp();
        W = comps[0];
        S = comps[1];
        D = comps[2];
        pNum = [uint256(1), 10, 1];
        pDen = [uint256(1), 1, 1000];

        sLiq = _newPair(S, 1e13, 1e14); // 10 M SAUCE / 1 M W
        dLiq = _newPair(D, 1e17, 1e14); // 1.000 M DOVU / 1 M W
        sIll = _newPair(S, 1e11, 1e12); // 100 k SAUCE / 10 k W
        dIll = _newPair(D, 1e15, 1e12); // 10 M DOVU / 10 k W

        hPool = new MockPair(h10x, W);
        _assoc(address(hPool), h10x);
        _assoc(address(hPool), W);
        vm.prank(owner);
        IERC20(h10x).transfer(address(hPool), 100e8);
        IERC20(W).transfer(address(hPool), 1_000e8);

        address[3] memory actors = [whale, arb, attacker];
        for (uint256 a; a < 3; ++a) {
            _assocAll(actors[a]);
            IERC20(W).transfer(actors[a], 1e16);
            IERC20(S).transfer(actors[a], 1e15);
            IERC20(D).transfer(actors[a], 1e17);
            _approveAll(actors[a]);
            _approvePairs(actors[a]);
        }
        vm.prank(owner);
        IERC20(h10x).transfer(whale, 800e8);
    }

    // ═══════════════════ tablas (se ven con -vv) ═══════════════════

    function test_table_whaleBuy_pegRecovery() public {
        console.log("");
        console.log("=== Ballena COMPRA H10X en el pool (100 H10X / 1.000 W; NAV 10 W) ===");
        console.log("compra W | prima tras ballena pb | prima tras arbitraje pb | ganancia arb W | perdida ballena W");
        uint256[4] memory sizes = [uint256(10e8), 100e8, 500e8, 2_000e8];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 snap = vm.snapshotState();
            uint256[3] memory b0 = _backing();
            int256 whale0 = int256(_value(whale));
            _whaleBuy(sizes[k]);
            int256 prem1 = _premiumBps();
            (int256 profit,) = _arb(INKIND_PREMIUM);
            int256 prem2 = _premiumBps();
            int256 whaleLoss = whale0 - int256(_value(whale));
            _log5(sizes[k] / 1e8, prem1, prem2, profit / 1e8, whaleLoss / 1e8);
            assertLe(prem2, BAND_BPS, "el arbitraje devuelve el precio a la banda");
            assertGe(prem2, -BAND_BPS, "sin pasarse de largo");
            assertLe(profit, whaleLoss, "el arbitrajista solo gana lo que pierde la ballena");
            _assertBackingNotBelow(b0);
            vm.revertToStateAndDelete(snap);
        }
    }

    function test_table_whaleDump_pegRecovery() public {
        console.log("");
        console.log("=== Ballena VENDE H10X en el pool ===");
        console.log("vende H10X | prima tras ballena pb | prima tras arbitraje pb | ganancia arb W | perdida ballena W");
        uint256[4] memory sizes = [uint256(1e8), 10e8, 50e8, 200e8];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 snap = vm.snapshotState();
            uint256[3] memory b0 = _backing();
            int256 whale0 = int256(_value(whale));
            _whaleSell(sizes[k]);
            int256 prem1 = _premiumBps();
            (int256 profit,) = _arb(INKIND_DISCOUNT);
            int256 prem2 = _premiumBps();
            int256 whaleLoss = whale0 - int256(_value(whale));
            _log5(sizes[k] / 1e8, prem1, prem2, profit / 1e8, whaleLoss / 1e8);
            assertGe(prem2, -BAND_BPS, "el arbitraje devuelve el precio a la banda");
            assertLe(prem2, BAND_BPS, "sin pasarse de largo");
            assertLe(profit, whaleLoss, "el arbitrajista solo gana lo que pierde la ballena");
            _assertBackingNotBelow(b0);
            vm.revertToStateAndDelete(snap);
        }
    }

    /// Qué banda queda según cómo arbitre el arbitrajista y la liquidez de los componentes.
    function test_table_bandByArbitrageMode() public {
        console.log("");
        console.log("=== Banda final tras una compra de 100 W segun el tipo de arbitraje ===");
        int256[3] memory prem;
        for (uint256 m; m < 3; ++m) {
            uint256 snap = vm.snapshotState();
            _whaleBuy(100e8);
            _arb(m == 0 ? INKIND_PREMIUM : m == 1 ? BUY_BASKET_LIQ : BUY_BASKET_ILL);
            prem[m] = _premiumBps();
            vm.revertToStateAndDelete(snap);
        }
        console.log("con cesta en inventario (pb):          ", prem[0]);
        console.log("sin inventario, componentes liquidos:  ", prem[1]);
        console.log("sin inventario, componentes iliquidos: ", prem[2]);
        assertLe(prem[0], BAND_BPS);
        assertLe(prem[0], prem[1], "comprar la cesta en el mercado ensancha la banda");
        assertLt(prem[1], prem[2], "con componentes iliquidos la banda es mas ancha");
    }

    // ═══════════════════ fuzz ═══════════════════

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_whaleBuy_arbBounded_backingSafe(uint256 amountW) public {
        amountW = bound(amountW, 1e7, 5_000e8);
        uint256[3] memory b0 = _backing();
        int256 whale0 = int256(_value(whale));
        _whaleBuy(amountW);
        (int256 profit,) = _arb(INKIND_PREMIUM);
        assertLe(_premiumBps(), BAND_BPS);
        assertLe(profit, whale0 - int256(_value(whale)));
        _assertBackingNotBelow(b0);
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_whaleDump_arbBounded_backingSafe(uint256 shares) public {
        shares = bound(shares, 1e6, 800e8);
        uint256[3] memory b0 = _backing();
        int256 whale0 = int256(_value(whale));
        _whaleSell(shares);
        (int256 profit,) = _arb(INKIND_DISCOUNT);
        assertGe(_premiumBps(), -BAND_BPS);
        assertLe(profit, whale0 - int256(_value(whale)));
        _assertBackingNotBelow(b0);
    }

    // ═══════════════════ ataques ═══════════════════

    /// En el NAV no hay nada que ganar: emitir+vender y comprar+reembolsar pierden siempre.
    function test_atPeg_noArbitrageProfit() public {
        uint256[3] memory b0 = _backing();
        (int256 p1, uint256 t1) = _arb(INKIND_PREMIUM);
        (int256 p2, uint256 t2) = _arb(INKIND_DISCOUNT);
        assertEq(t1 + t2, 0);
        assertEq(p1, 0);
        assertEq(p2, 0);
        _assertBackingNotBelow(b0);
    }

    /// Inflar el precio de un componente (pool ilíquido) no cambia lo que se aporta ni lo que se recibe:
    /// emitir y reembolsar son proporcionales a las tenencias y no miran precios.
    function test_attack_pumpComponent_vaultUnaffected() public {
        (uint256[] memory qi0,) = vault.quoteIssue(10e8);
        uint256[] memory qr0 = vault.quoteRedeem(10e8);
        int256 v0 = int256(_value(attacker));

        vm.prank(attacker);
        uint256 dGot = dIll.swapExactIn(W, 5_000e8, 0, attacker); // bombea DOVU ~×2,2 en el pool ilíquido

        (uint256[] memory qi1,) = vault.quoteIssue(10e8);
        uint256[] memory qr1 = vault.quoteRedeem(10e8);
        for (uint256 i; i < 3; ++i) {
            assertEq(qi1[i], qi0[i]);
            assertEq(qr1[i], qr0[i]);
        }
        vm.prank(attacker);
        dIll.swapExactIn(D, dGot, 0, attacker); // deshace
        assertLt(int256(_value(attacker)), v0, "el atacante solo pierde comisiones");
    }

    /// Sandwich a un rebalanceo (peor caso: el atacante sabe que viene). Lo que puede extraer está acotado por la
    /// tolerancia (minOut) que ponga el rebalancer. Tabla para decidir esa tolerancia.
    function test_table_sandwichRebalance_byTolerance() public {
        _installPairRouter();
        uint256 amountIn = _vaultBal(2) / 10; // vende 10 % del DOVU (≈200 W) en el pool ilíquido (2 % del pool)
        address[] memory path = new address[](2);
        path[0] = D;
        path[1] = W;
        uint16[4] memory tols = [uint16(30), 50, 200, 500];

        console.log("");
        console.log("=== Sandwich a un rebalanceo (vende 200k DOVU en pool iliquido) ===");
        console.log("tolerancia pb | perdida vault pb | ganancia atacante W*1e4");
        for (uint256 k; k < tols.length; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 minOut = (dIll.getAmountOut(D, amountIn) * (10_000 - tols[k])) / 10_000;

            uint256 s2 = vm.snapshotState();
            vm.prank(rebalancer);
            uint256 honest = vault.rebalanceV1(path, amountIn, minOut, block.timestamp);
            vm.revertToStateAndDelete(s2);

            uint256 front = _maxFrontRun(amountIn, minOut);
            int256 a0 = int256(_value(attacker));
            vm.prank(attacker);
            uint256 wGot = dIll.swapExactIn(D, front, 0, attacker);
            vm.prank(rebalancer);
            uint256 got = vault.rebalanceV1(path, amountIn, minOut, block.timestamp);
            vm.prank(attacker);
            dIll.swapExactIn(W, wGot, 0, attacker);
            int256 atkPnl = int256(_value(attacker)) - a0;
            uint256 lossBps = ((honest - got) * 10_000) / honest;

            console.log(string.concat(vm.toString(tols[k]), " | ", vm.toString(lossBps), " | ", vm.toString(atkPnl / 1e4)));
            assertGe(got, minOut);
            assertLe(lossBps, tols[k], "la perdida nunca supera la tolerancia");
            assertLe(atkPnl, int256(honest - got), "el atacante no gana mas de lo que pierde el vault");
            vm.revertToStateAndDelete(snap);
        }
    }

    /// Si el atacante empuja más allá de la tolerancia, el rebalanceo revierte y el vault no pierde nada.
    function test_attack_sandwichBeyondTolerance_reverts() public {
        _installPairRouter();
        uint256 amountIn = _vaultBal(2) / 10;
        address[] memory path = new address[](2);
        path[0] = D;
        path[1] = W;
        uint256 minOut = (dIll.getAmountOut(D, amountIn) * 9_950) / 10_000;
        uint256 front = _maxFrontRun(amountIn, minOut);
        vm.prank(attacker);
        dIll.swapExactIn(D, front + front / 10 + 1e8, 0, attacker);
        vm.prank(rebalancer);
        vm.expectRevert();
        vault.rebalanceV1(path, amountIn, minOut, block.timestamp);
    }

    // ═══════════════════ actores ═══════════════════

    function _whaleBuy(uint256 amountW) internal {
        vm.prank(whale);
        hPool.swapExactIn(W, amountW, 0, whale);
    }

    function _whaleSell(uint256 shares) internal {
        vm.prank(whale);
        hPool.swapExactIn(h10x, shares, 0, whale);
    }

    // Modos de arbitraje
    uint8 internal constant INKIND_PREMIUM = 0; // con cesta en inventario: emite y vende (precio > NAV)
    uint8 internal constant BUY_BASKET_LIQ = 1; // sin inventario: compra la cesta en pools líquidos, emite y vende
    uint8 internal constant BUY_BASKET_ILL = 2; // igual con pools ilíquidos
    uint8 internal constant INKIND_DISCOUNT = 3; // compra H10X en el pool y reembolsa (precio < NAV)

    /// Arbitrajista racional: opera por trozos mientras el trozo gane Y el margen siguiente siga ganando
    /// (así no se pasa de largo del NAV). Los trozos que no cumplen se deshacen y se prueba con la mitad.
    function _arb(uint8 mode) internal returns (int256 profit, uint256 trades) {
        int256 v0 = _arbWealth(mode);
        uint256 chunk = mode == INKIND_DISCOUNT ? 100e8 : 10e8;
        uint256 probe = mode == INKIND_DISCOUNT ? 1e7 : 1e6;
        for (uint256 it; it < 500 && chunk >= probe; ++it) {
            uint256 snap = vm.snapshotState();
            bool ok = _step(mode, chunk) > 0;
            if (ok) {
                uint256 s2 = vm.snapshotState();
                ok = _step(mode, probe) > 0;
                vm.revertToStateAndDelete(s2);
            }
            if (ok) {
                vm.deleteStateSnapshot(snap);
                trades++;
            } else {
                vm.revertToStateAndDelete(snap);
                chunk /= 2;
            }
        }
        profit = _arbWealth(mode) - v0;
    }

    /// Riqueza del arbitrajista: a precios justos si usa inventario; en W si solo opera con W.
    function _arbWealth(uint8 mode) internal view returns (int256) {
        return mode == BUY_BASKET_LIQ || mode == BUY_BASKET_ILL
            ? int256(IERC20(W).balanceOf(arb))
            : int256(_value(arb));
    }

    function _step(uint8 mode, uint256 size) internal returns (int256 pnl) {
        int256 before = _arbWealth(mode);
        vm.startPrank(arb);
        if (mode == INKIND_DISCOUNT) {
            uint256 got = hPool.swapExactIn(W, size, 0, arb);
            vault.redeem(got, _zeros(), arb, 0, CfgVersion.get(address(vault)));
        } else {
            (uint256[] memory need,) = vault.quoteIssue(size);
            if (mode != INKIND_PREMIUM) {
                (MockPair sp, MockPair dp) = mode == BUY_BASKET_LIQ ? (sLiq, dLiq) : (sIll, dIll);
                sp.swapExactOut(S, need[1], type(uint256).max, arb);
                dp.swapExactOut(D, need[2], type(uint256).max, arb);
            }
            (uint256 net,) = vault.issue(size, need, arb, CfgVersion.get(address(vault)));
            hPool.swapExactIn(h10x, net, 0, arb);
        }
        vm.stopPrank();
        pnl = _arbWealth(mode) - before;
    }

    /// Mayor venta previa de DOVU que aún deja pasar el rebalanceo (búsqueda binaria).
    function _maxFrontRun(uint256 amountIn, uint256 minOut) internal returns (uint256 lo) {
        uint256 hi = 1e16;
        for (uint256 k; k < 70 && lo + 1 < hi; ++k) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            dIll.swapExactIn(D, mid, 0, attacker);
            bool ok = dIll.getAmountOut(D, amountIn) >= minOut;
            vm.revertToStateAndDelete(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
    }

    // ═══════════════════ utilidades ═══════════════════

    function _newPair(address t, uint256 rt, uint256 rw) internal returns (MockPair p) {
        p = new MockPair(t, W);
        _assoc(address(p), t);
        _assoc(address(p), W);
        IERC20(t).transfer(address(p), rt);
        IERC20(W).transfer(address(p), rw);
    }

    function _approvePairs(address who) internal {
        address[5] memory pairs = [address(hPool), address(sLiq), address(dLiq), address(sIll), address(dIll)];
        address[4] memory tokens = [W, S, D, h10x];
        vm.startPrank(who);
        for (uint256 p; p < 5; ++p) {
            for (uint256 t; t < 4; ++t) {
                IERC20(tokens[t]).approve(pairs[p], type(uint256).max);
            }
        }
        vm.stopPrank();
    }

    function _installPairRouter() internal {
        vm.etch(address(r1), address(new PairRouterV1()).code);
        PairRouterV1(address(r1)).setPair(D, W, address(dIll));
    }

    /// NAV por unidad de H10X, en W, escalado 1e18, a precios justos.
    function _navE18() internal view returns (uint256 v) {
        for (uint256 i; i < 3; ++i) {
            v += (_vaultBal(i) * pNum[i] * 1e18) / pDen[i];
        }
        v /= vault.totalSupply();
    }

    function _premiumBps() internal view returns (int256) {
        uint256 price = (hPool.reserveOf(W) * 1e18) / hPool.reserveOf(h10x);
        uint256 nav = _navE18();
        return ((int256(price) - int256(nav)) * 10_000) / int256(nav);
    }

    function _value(address who) internal view returns (uint256 v) {
        for (uint256 i; i < 3; ++i) {
            v += (IERC20(comps[i]).balanceOf(who) * pNum[i]) / pDen[i];
        }
        v += (IERC20(h10x).balanceOf(who) * _navE18()) / 1e18;
    }

    function _backing() internal view returns (uint256[3] memory b) {
        uint256 supply = vault.totalSupply();
        for (uint256 i; i < 3; ++i) {
            b[i] = (_vaultBal(i) * 1e18) / supply;
        }
    }

    function _assertBackingNotBelow(uint256[3] memory prev) internal view {
        uint256[3] memory b = _backing();
        for (uint256 i; i < 3; ++i) {
            assertGe(b[i], prev[i], "el respaldo por H10X no puede bajar");
        }
    }

    function _log5(uint256 a, int256 b, int256 c, int256 d, int256 e) internal pure {
        console.log(string.concat(
            vm.toString(a), " | ", vm.toString(b), " | ", vm.toString(c), " | ", vm.toString(d), " | ", vm.toString(e)
        ));
    }
}

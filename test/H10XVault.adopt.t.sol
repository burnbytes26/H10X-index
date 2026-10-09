// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHederaTokenService} from "@hiero/token-service/IHederaTokenService.sol";

import {H10XVault} from "../src/H10XVault.sol";
import {MockHTS} from "./mocks/MockHTS.sol";
import {MockRouterV1, MockRouterV2} from "./mocks/MockRouters.sol";
import {CfgVersion} from "./utils/CfgVersion.sol";

/// @notice initializeWithToken: la bóveda adopta un token H10X creado por HAPI (con metadata key para el logo)
///         solo si cumple lo mismo que garantiza initialize (tesorería y supply key = bóveda, sin otras claves…).
contract H10XVaultAdoptTest is Test {
    MockHTS internal hts = MockHTS(address(0x167));
    H10XVault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal feeRec = makeAddr("feeRecipient");
    address[] internal comps;
    uint16[] internal weights;

    function setUp() public {
        vm.etch(address(0x167), address(new MockHTS()).code);
        comps.push(_createToken("Wrapped HBAR", "tWHBAR", 8));
        comps.push(_createToken("Sauce", "tSAUCE", 6));
        weights.push(6000);
        weights.push(4000);
        MockRouterV1 r1 = new MockRouterV1();
        MockRouterV2 r2 = new MockRouterV2();
        vm.prank(owner);
        vault = new H10XVault(feeRec, owner, owner, address(r1), address(r2), 50, 50, 2000);
    }

    function _createToken(string memory name, string memory symbol, uint8 dec) internal returns (address token) {
        IHederaTokenService.HederaToken memory t;
        t.name = name;
        t.symbol = symbol;
        t.treasury = address(this);
        t.expiry.autoRenewPeriod = 7_776_000;
        int64 rc;
        (rc, token) = hts.createFungibleToken{value: 1}(t, int64(uint64(1e18)), int32(uint32(dec)));
        require(rc == 22, "create failed");
    }

    function _good() internal returns (address) {
        return hts.hapiCreate(address(vault), address(vault), 0, 8, 0);
    }

    function _adopt(address token) internal {
        vm.prank(owner);
        vault.initializeWithToken(token, comps, weights);
    }

    function _expectNotAdoptable(address token, string memory why) internal {
        vm.expectRevert(abi.encodeWithSelector(H10XVault.TokenNotAdoptable.selector, why));
        _adopt(token);
    }

    function _assoc(address account, address token) internal {
        vm.prank(account);
        hts.associateToken(account, token);
    }

    // ───────────── camino bueno ─────────────

    function test_adopt_thenSeedIssueRedeem() public {
        address token = _good();
        _adopt(token);
        assertEq(vault.h10x(), token);
        assertEq(vault.components().length, 2);
        assertEq(vault.targetWeightBps(comps[0]), 6000);
        assertTrue(hts.isAssociated(comps[1], address(vault)));

        // seed del owner
        for (uint256 i; i < comps.length; ++i) {
            _assoc(owner, comps[i]);
            _assoc(alice, comps[i]);
            IERC20(comps[i]).transfer(owner, 1e15);
            IERC20(comps[i]).transfer(alice, 1e15);
        }
        _assoc(owner, token);
        _assoc(alice, token);
        vm.startPrank(owner);
        IERC20(comps[0]).approve(address(vault), type(uint256).max);
        IERC20(comps[1]).approve(address(vault), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 600e8;
        amounts[1] = 4_000e6;
        vault.seed(amounts, 100e8, owner);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(owner), 100e8);
        assertEq(IERC20(token).totalSupply(), 100e8);

        // emisión y reembolso de un tercero
        vm.startPrank(alice);
        IERC20(comps[0]).approve(address(vault), type(uint256).max);
        IERC20(comps[1]).approve(address(vault), type(uint256).max);
        IERC20(token).approve(address(vault), type(uint256).max);
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint256).max;
        maxIn[1] = type(uint256).max;
        (uint256 got,) = vault.issue(10e8, maxIn, alice, CfgVersion.get(address(vault)));
        assertEq(got, 10e8 - (10e8 * 50) / 10_000);
        vault.redeem(got, new uint256[](2), alice, 0, CfgVersion.get(address(vault)));
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(alice), 0);
    }

    function test_adopt_emitsInitialized() public {
        address token = _good();
        vm.expectEmit(true, false, false, false, address(vault));
        emit H10XVault.Initialized(token);
        _adopt(token);
    }

    // ───────────── permisos y estado ─────────────

    function test_adopt_revert_notOwner() public {
        address token = _good();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.initializeWithToken(token, comps, weights);
    }

    function test_adopt_revert_twice() public {
        _adopt(_good());
        address other = _good();
        vm.expectRevert(H10XVault.AlreadyInitialized.selector);
        _adopt(other);
    }

    function test_initialize_revert_afterAdopt() public {
        _adopt(_good());
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vm.expectRevert(H10XVault.AlreadyInitialized.selector);
        vault.initialize{value: 1 ether}("H10X", "H10X", "", comps, weights);
    }

    function test_adopt_revert_afterInitialize() public {
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vault.initialize{value: 1 ether}("H10X", "H10X", "", comps, weights);
        address token = _good();
        vm.expectRevert(H10XVault.AlreadyInitialized.selector);
        _adopt(token);
    }

    function test_adopt_revert_zeroToken() public {
        vm.expectRevert(H10XVault.ZeroAddress.selector);
        _adopt(address(0));
    }

    function test_adopt_revert_unknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(H10XVault.HtsError.selector, int64(167)));
        _adopt(makeAddr("notAToken"));
    }

    function test_adopt_revert_badBasket() public {
        address token = _good();
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        vm.prank(owner);
        vm.expectRevert(H10XVault.BadComponents.selector);
        vault.initializeWithToken(token, comps, w);
        w = new uint16[](2);
        w[0] = 5000;
        w[1] = 4000;
        vm.prank(owner);
        vm.expectRevert(H10XVault.WeightsMustSum10000.selector);
        vault.initializeWithToken(token, comps, w);
        assertEq(vault.h10x(), address(0)); // todo revertido
    }

    // ───────────── requisitos del token ─────────────

    function test_adopt_revert_treasuryNotVault() public {
        _expectNotAdoptable(hts.hapiCreate(makeAddr("someone"), address(vault), 0, 8, 0), "treasury");
    }

    function test_adopt_revert_initialSupply() public {
        _expectNotAdoptable(hts.hapiCreate(address(vault), address(vault), 0, 8, 1e8), "supply");
    }

    function test_adopt_revert_decimals() public {
        _expectNotAdoptable(hts.hapiCreate(address(vault), address(vault), 0, 6, 0), "decimals");
    }

    function test_adopt_revert_supplyKeyOtherContract() public {
        _expectNotAdoptable(hts.hapiCreate(address(vault), makeAddr("other"), 0, 8, 0), "supply key");
    }

    function test_adopt_revert_noSupplyKey() public {
        _expectNotAdoptable(hts.hapiCreate(address(vault), address(0), 0, 8, 0), "supply key");
    }

    function test_adopt_revert_supplyKeyEd25519() public {
        address token = _good();
        hts.setTokenFlags(token, false, false, false, true);
        _expectNotAdoptable(token, "supply key");
    }

    function test_adopt_revert_customFees() public {
        address token = _good();
        hts.setHasCustomFees(token, true);
        _expectNotAdoptable(token, "custom fees");
    }

    function test_adopt_revert_finiteSupply() public {
        address token = _good();
        hts.setTokenFlags(token, true, false, false, false);
        _expectNotAdoptable(token, "finite supply");
    }

    function test_adopt_revert_freezeDefault() public {
        address token = _good();
        hts.setTokenFlags(token, false, true, false, false);
        _expectNotAdoptable(token, "freeze default");
    }

    function test_adopt_revert_deleted() public {
        address token = _good();
        hts.setTokenFlags(token, false, false, true, false);
        _expectNotAdoptable(token, "deleted/paused");
    }

    /// Cualquier clave prohibida (admin, kyc, freeze, wipe, fee schedule, pause) bloquea la adopción.
    function test_adopt_revert_forbiddenKeys() public {
        uint8[6] memory keys = [1, 2, 4, 8, 32, 64];
        for (uint256 i; i < keys.length; ++i) {
            address token = hts.hapiCreate(address(vault), address(vault), keys[i], 8, 0);
            vm.expectRevert(abi.encodeWithSelector(H10XVault.TokenHasForbiddenKey.selector, uint256(keys[i])));
            _adopt(token);
        }
        assertEq(vault.h10x(), address(0));
    }

    function testFuzz_adopt_revert_anyForbiddenCombo(uint8 mask) public {
        uint256 forbidden = uint256(mask) & (1 | 2 | 4 | 8 | 32 | 64);
        vm.assume(forbidden != 0);
        address token = hts.hapiCreate(address(vault), address(vault), forbidden, 8, 0);
        vm.prank(owner);
        vm.expectRevert(); // la primera clave presente, en orden admin → pause
        vault.initializeWithToken(token, comps, weights);
    }
}

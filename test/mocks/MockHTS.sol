// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHederaTokenService} from "@hiero/token-service/IHederaTokenService.sol";

/// @notice Token HTS simulado: ERC-20 (fachada HIP-218) cuyo mint/burn solo puede hacer el "HTS" (0x167)
///         y que exige asociación previa del receptor, como en Hedera.
contract MockHTSToken is ERC20 {
    address internal constant HTS = address(0x167);
    uint8 internal immutable _dec;
    /// @notice Solo tests: comisión por transferencia (se quema) para simular custom fees.
    uint16 public transferFeeBps;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function htsMint(address to, uint256 amount) external {
        require(msg.sender == HTS, "only HTS");
        _mint(to, amount);
    }

    function htsBurn(address from, uint256 amount) external {
        require(msg.sender == HTS, "only HTS");
        _burn(from, amount);
    }

    function setTransferFeeBps(uint16 bps) external {
        transferFeeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        // Hedera: a deleted token cannot be transferred, minted or burned (balanceOf keeps working)
        require(!MockHTS(HTS).isDeletedToken(address(this)), "TOKEN_WAS_DELETED");
        if (to != address(0)) {
            require(MockHTS(HTS).isAssociated(address(this), to), "TOKEN_NOT_ASSOCIATED_TO_ACCOUNT");
        }
        if (from != address(0) && to != address(0) && transferFeeBps != 0) {
            uint256 fee = (value * transferFeeBps) / 10_000;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Simulación mínima del system contract HTS en 0x167 para tests locales.
/// @dev    Se instala con `vm.etch(address(0x167), address(new MockHTS()).code)`. Sin estado en constructor.
///         Reproduce la semántica que importa a la bóveda: supply key tipo contractId, tesorería,
///         asociación obligatoria y códigos de respuesta.
contract MockHTS {
    int64 internal constant SUCCESS = 22;
    int64 internal constant INVALID_SIGNATURE = 7;
    int64 internal constant INVALID_TOKEN_ID = 167;
    int64 internal constant TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT = 194;
    int64 internal constant INVALID_TREASURY_ACCOUNT_FOR_TOKEN = 36;

    int64 internal constant KEY_NOT_PROVIDED = 44;
    int64 internal constant TOKEN_WAS_DELETED = 179;

    struct TokenData {
        bool exists;
        address treasury;
        address supplyContract;
        uint256 keyMask;
        bool hasCustomFees;
        // solo tokens creados con hapiCreate (fuera de un contrato)
        bool hapi;
        uint8 decimals;
        bool finiteSupply;
        bool freezeDefault;
        bool deleted;
        bool supplyKeyIsEd25519; // supply key presente pero no es un contrato
    }

    mapping(address => TokenData) public tokenData;
    mapping(address => mapping(address => bool)) internal _associated;
    uint256 public createCount;
    uint256 public lastCreateValue;

    function isAssociated(address token, address account) external view returns (bool) {
        return _associated[token][account];
    }

    function isDeletedToken(address token) external view returns (bool) {
        return tokenData[token].deleted;
    }

    function keyMaskOf(address token) external view returns (uint256) {
        return tokenData[token].keyMask;
    }

    function supplyContractOf(address token) external view returns (address) {
        return tokenData[token].supplyContract;
    }

    function treasuryOf(address token) external view returns (address) {
        return tokenData[token].treasury;
    }

    /// @notice Solo tests.
    function setHasCustomFees(address token, bool v) external {
        tokenData[token].hasCustomFees = v;
    }

    function createFungibleToken(IHederaTokenService.HederaToken memory token, int64 initialTotalSupply, int32 decimals_)
        external
        payable
        returns (int64 responseCode, address tokenAddress)
    {
        // La tesorería debe "firmar": en Hedera, un contrato solo puede ponerse a sí mismo.
        if (token.treasury != msg.sender) return (INVALID_TREASURY_ACCOUNT_FOR_TOKEN, address(0));
        require(msg.value > 0, "INSUFFICIENT_TX_FEE");
        lastCreateValue = msg.value;

        MockHTSToken t = new MockHTSToken(token.name, token.symbol, uint8(uint32(decimals_)));
        tokenAddress = address(t);
        TokenData storage d = tokenData[tokenAddress];
        d.exists = true;
        d.treasury = token.treasury;
        for (uint256 i; i < token.tokenKeys.length; ++i) {
            d.keyMask |= token.tokenKeys[i].keyType;
            if (token.tokenKeys[i].keyType & 16 != 0) d.supplyContract = token.tokenKeys[i].key.contractId;
        }
        _associated[tokenAddress][token.treasury] = true;
        if (initialTotalSupply > 0) t.htsMint(token.treasury, uint256(uint64(initialTotalSupply)));
        createCount++;
        responseCode = SUCCESS;
    }

    /// @notice Solo tests: TokenCreate por HAPI (fuera de un contrato; la tesorería "firma" con su clave).
    ///         `extraKeyMask` añade claves de tipo ed25519 (admin 1, kyc 2, freeze 4, wipe 8, fee 32, pause 64).
    function hapiCreate(address treasury, address supplyContract, uint256 extraKeyMask, uint8 decimals_, uint256 initialSupply)
        external
        returns (address tokenAddress)
    {
        MockHTSToken t = new MockHTSToken("H10X Index", "H10X", decimals_);
        tokenAddress = address(t);
        TokenData storage d = tokenData[tokenAddress];
        d.exists = true;
        d.hapi = true;
        d.treasury = treasury;
        d.decimals = decimals_;
        d.supplyContract = supplyContract;
        d.keyMask = extraKeyMask | (supplyContract != address(0) ? 16 : 0);
        _associated[tokenAddress][treasury] = true;
        if (initialSupply > 0) t.htsMint(treasury, initialSupply);
    }

    /// @notice Solo tests: variantes de token para probar la adopción.
    function setTokenFlags(address token, bool finite, bool freezeDefault_, bool deleted_, bool supplyEd25519) external {
        TokenData storage d = tokenData[token];
        d.finiteSupply = finite;
        d.freezeDefault = freezeDefault_;
        d.deleted = deleted_;
        d.supplyKeyIsEd25519 = supplyEd25519;
        if (supplyEd25519) {
            d.supplyContract = address(0);
            d.keyMask |= 16;
        }
    }

    function getFungibleTokenInfo(address token)
        external
        view
        returns (int64 responseCode, IHederaTokenService.FungibleTokenInfo memory info)
    {
        TokenData storage d = tokenData[token];
        if (!d.exists) return (INVALID_TOKEN_ID, info);
        info.tokenInfo.token.name = MockHTSToken(token).name();
        info.tokenInfo.token.symbol = MockHTSToken(token).symbol();
        info.tokenInfo.token.treasury = d.treasury;
        info.tokenInfo.token.tokenSupplyType = d.finiteSupply;
        info.tokenInfo.token.freezeDefault = d.freezeDefault;
        info.tokenInfo.totalSupply = int64(uint64(MockHTSToken(token).totalSupply()));
        info.tokenInfo.deleted = d.deleted;
        if (d.hasCustomFees) {
            info.tokenInfo.fixedFees = new IHederaTokenService.FixedFee[](1);
            info.tokenInfo.fixedFees[0].amount = 1;
            info.tokenInfo.fixedFees[0].useHbarsForPayment = true;
        }
        info.decimals = int32(uint32(d.hapi ? d.decimals : MockHTSToken(token).decimals()));
        responseCode = SUCCESS;
    }

    /// @dev Como Hedera (llamada no estática): KEY_NOT_PROVIDED si la clave no existe; SUCCESS si existe.
    function getTokenKey(address token, uint256 keyType)
        external
        view
        returns (int64 responseCode, IHederaTokenService.KeyValue memory key)
    {
        TokenData storage d = tokenData[token];
        if (!d.exists) return (INVALID_TOKEN_ID, key);
        if (d.keyMask & keyType == 0) return (KEY_NOT_PROVIDED, key);
        if (keyType == 16 && d.supplyContract != address(0)) key.contractId = d.supplyContract;
        else key.ed25519 = hex"0102030405060708091011121314151617181920212223242526272829303132";
        responseCode = SUCCESS;
    }

    function mintToken(address token, int64 amount, bytes[] memory)
        external
        returns (int64 responseCode, int64 newTotalSupply, int64[] memory serialNumbers)
    {
        TokenData storage d = tokenData[token];
        if (!d.exists) return (INVALID_TOKEN_ID, 0, serialNumbers);
        if (d.supplyContract == address(0) || msg.sender != d.supplyContract) {
            return (INVALID_SIGNATURE, 0, serialNumbers);
        }
        MockHTSToken(token).htsMint(d.treasury, uint256(uint64(amount)));
        return (SUCCESS, int64(uint64(MockHTSToken(token).totalSupply())), serialNumbers);
    }

    function burnToken(address token, int64 amount, int64[] memory)
        external
        returns (int64 responseCode, int64 newTotalSupply)
    {
        TokenData storage d = tokenData[token];
        if (!d.exists) return (INVALID_TOKEN_ID, 0);
        if (d.supplyContract == address(0) || msg.sender != d.supplyContract) return (INVALID_SIGNATURE, 0);
        MockHTSToken(token).htsBurn(d.treasury, uint256(uint64(amount)));
        return (SUCCESS, int64(uint64(MockHTSToken(token).totalSupply())));
    }

    function associateToken(address account, address token) public returns (int64 responseCode) {
        if (msg.sender != account) return INVALID_SIGNATURE;
        if (!tokenData[token].exists) return INVALID_TOKEN_ID;
        if (tokenData[token].deleted && !_associated[token][account]) return TOKEN_WAS_DELETED;
        if (_associated[token][account]) return TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT;
        _associated[token][account] = true;
        return SUCCESS;
    }

    function associateTokens(address account, address[] memory tokens) external returns (int64 responseCode) {
        for (uint256 i; i < tokens.length; ++i) {
            responseCode = associateToken(account, tokens[i]);
            if (responseCode != SUCCESS) return responseCode;
        }
        return SUCCESS;
    }

    function getTokenCustomFees(address token)
        external
        view
        returns (
            int64 responseCode,
            IHederaTokenService.FixedFee[] memory fixedFees,
            IHederaTokenService.FractionalFee[] memory fractionalFees,
            IHederaTokenService.RoyaltyFee[] memory royaltyFees
        )
    {
        if (!tokenData[token].exists) return (INVALID_TOKEN_ID, fixedFees, fractionalFees, royaltyFees);
        if (tokenData[token].hasCustomFees) {
            fixedFees = new IHederaTokenService.FixedFee[](1);
            fixedFees[0].amount = 1;
            fixedFees[0].useHbarsForPayment = true;
        }
        responseCode = SUCCESS;
    }
}

# Security policy

## Scope

`src/H10XVault.sol`, deployed on Hedera mainnet as contract `0.0.10907483` (H10XVault 1.3.0), and the H10X token
`0.0.10907484`.

## Reporting a vulnerability

Please email **h10xindex@gmail.com** with:

- a description of the issue and its impact,
- steps or a test that reproduces it (a Foundry test against this repository is ideal),
- whether you believe funds are at risk now.

Please do not disclose the issue publicly until we have replied and, where possible, mitigated it. The vault is
immutable, so mitigations are operational: the multisig can pause new issuance and adjust governance settings, while
redemptions always stay open.

We will acknowledge your report as soon as we can and keep you informed while we investigate.

## Status

The contract has had a self-review (static analysis, two manual review rounds, extensive testing and testnet
rehearsals). It has not yet had an independent audit. See [`security/`](security).

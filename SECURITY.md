# Security

## Report a vulnerability

Send your report from the form at **https://h10xindex.xyz/security/#report** or by email to **h10xindex@gmail.com**.
Please include what happens, why, and how to reproduce it (transaction IDs or a Foundry test). Don't disclose it
publicly until we have answered and holders are protected.

## Bug bounty (closed)

The bug bounty ran on Hedera testnet until **6 November 2026**, with $2,000 in HBAR for a critical vulnerability in the
vault. **No critical issue was found**: no report could steal from the vault, mint H10X without the basket or alter what
backs it. Every finding was minor, informational or not possible on Hedera, and the contract didn't need to change.

The full results, with every finding, who reported it and what we did, are at
**https://h10xindex.xyz/security/bounty/** and in [`security/bug-bounty-2026-11.md`](security/bug-bounty-2026-11.md).

## Review status

The vault has had a self-review by the H10X team (static analysis, two manual review rounds, Foundry unit, fuzz and
invariant tests, and a testnet rehearsal) and a public bug bounty. It is not an independent audit.

| | Mainnet |
|---|---|
| Vault (H10XVault 1.3.0) | 0.0.10907483 |
| H10X token | 0.0.10907484 |
| Multisig (owner, rebalancer, guardian) | 0.0.10907480 |

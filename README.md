# bitcorn (BITCORN)

A plain, fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Parameter        | Value                                            |
| ---------------- | ------------------------------------------------ |
| Solidity contract | `BitcornToken` (`src/BitcornToken.sol`)         |
| `name()`         | `bitcorn`                                        |
| `symbol()`       | `BITCORN`                                        |
| `decimals()`     | `18`                                             |
| Total supply     | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Minting          | Once, in the constructor, all of it to `msg.sender` (the deployer) |
| Constructor args | none                                             |
| Compiler         | solc `0.8.26`, optimizer on (200 runs), `bytecode_hash = "none"`, EVM `cancun` |

## What the token does

The brief describes the token as "adam" and otherwise asks only for a fixed supply minted to the
deployer. No transfer rule, tax, burn, vesting, reflection or governance feature was requested, so
the token is a standard OpenZeppelin v5 `ERC20` with:

- the whole supply minted once in the constructor to `msg.sender`;
- no mint function, no owner, no pause, no blacklist, no freeze, no seize, no upgrade path, no
  `receive`/`fallback`, and no library linkage (every library call is internal);
- untaxed, unrestricted transfers, so every launch flow moves exactly what it says.

Assumption: "adam" is taken as a label with no behavioural content. If the requester meant a
specific mechanic by it, that mechanic is not implemented here and would need a follow-up brief.

## Layout

```
foundry.toml                 Foundry configuration (solc 0.8.26 pinned, bytecode_hash = "none")
remappings.txt               forge-std and @openzeppelin/contracts remappings
src/BitcornToken.sol         the token
test/BitcornToken.t.sol      success, failure, fuzz and launch-flow tests
lib/forge-std/               forge-std v1.11.0, vendored as ordinary files (no submodule)
lib/openzeppelin-contracts/  OpenZeppelin Contracts v5.4.0, vendored as ordinary files (no submodule)
```

Both dependencies are plain files so the project builds with no network. The vendored
OpenZeppelin tree keeps only `contracts/` plus its licence and docs; its tests, audits and
hardhat scaffolding were dropped.

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests run with any order, in parallel and with an empty environment: they read no environment
variables and deploy the token from a stub factory contract so `msg.sender` in the constructor
is a contract, as at launch. To reproduce the verifier's fuzz run:

```
FOUNDRY_FUZZ_SEED=0x8ad5f1311010d0915453317fa7bba7ce356d2d27a4c64ed09dc7cb50e30b9315 forge test
```

### What the tests cover

- Metadata (`name`, `symbol`, `decimals`) and the exact supply constant.
- The constructor mints the entire supply to the deployer in a single `Transfer` event, and the
  contract deploys to a predictable CREATE2 address.
- Launch flows (factory to distributor, distributor to claimant, factory to pool, factory to the
  remainder address) each arrive whole and leave the supply unchanged.
- `transfer`, `approve`, `transferFrom`, allowance decrement, infinite allowance.
- Failure paths: insufficient balance, insufficient or missing allowance, zero-address receiver
  and spender, each with the exact OpenZeppelin custom error.
- No common mint/admin selector exists for a stranger or for the deployer; no pause, blacklist,
  freeze, lock, burnFrom or seize selector exists; the deployer cannot pull a holder's tokens.
- No `owner()`, no `receive`/`fallback`, and the runtime bytecode contains no `DELEGATECALL`,
  `CALLCODE` or `SELFDESTRUCT` and fits EIP-170.
- Fuzz: transfers are exact and conserve supply; over-balance transfers revert; `transferFrom`
  respects the allowance.

## Deployment parameters

The launch is performed by IdentityMD's deployer through the ProjectFactory. This repository does
not deploy, broadcast, or hold keys, and does not write `launch.json`; the manifest step does.
The values the manifest step will use, for reference only:

- `token.contract`: `BitcornToken`
- `token.name` / `token.symbol` / `token.decimals`: `bitcorn` / `BITCORN` / `18`
- `token.constructorArgs`: `[]` (the constructor takes no arguments and calls no contract, so it
  deploys on an empty chain)
- `token.totalSupply`: `1000000000000000000000000000`
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee `12500`,
  tick spacing `60`, initial price `79228162514264337593543950336` (provenance only; the deployer
  derives the opening price from the market cap).
- Economics, copied from the job: `poolBps` 6000, `initialMarketCapWei`
  5800000000000000000000 (5,800 IMD for the whole supply), `remainderTo`
  `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`.

At launch the factory receives the full supply, forwards 10% to the launch's MerkleDistributor,
seeds the Uniswap v4 pool with 60%, and sends the remaining 30% to `remainderTo`. The token does
nothing special for any of these addresses because it taxes or restricts nothing.

## Operational responsibilities and trust assumptions

- **No admin.** There is no owner, minter, pauser or upgrader. Nobody, including the requester,
  can mint, freeze, pause, seize or change the token after deployment. This is deliberate: it is
  what makes the supply fixed and the launch flows exact.
- **Supply is final.** 1,000,000,000 BITCORN exist from the constructor onward. The supply can
  only shrink if holders send tokens to an unrecoverable address; there is no burn function.
- **Holders are responsible for their own keys and approvals.** The token follows standard
  ERC-20 allowance semantics; an infinite approval to a contract stays until the holder resets it.
- **After launch:** nothing to configure. The token has no owner-settable values, no outside
  contract dependencies and no post-deploy initialisation.
- **Source verification** on the block explorer after deployment is the deployer's step
  (`forge verify-contract` with solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`).

## Security notes

Checked against the eth-security checklist in `.imd/reads/skills/eth-security/REFERENCE.md`:
no external calls (so no reentrancy surface), no privileged functions (so no access-control
surface), no oracles, no proxies, no delegatecall, no signatures, no ether handling. Standard
OpenZeppelin v5.4.0 `ERC20` is used unmodified. Foundry's unit and fuzz tests were run; Slither
and Mythril were not available in this environment and were not run. Passing tests are not an
audit; an independent adversarial review is still advisable before anything holds other people's
funds, although this token itself holds nothing.

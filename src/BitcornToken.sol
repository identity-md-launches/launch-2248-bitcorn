// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title bitcorn (BITCORN)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 BITCORN (18 decimals)
///         is minted once, in the constructor, to the deployer (`msg.sender`). Nothing can mint
///         afterwards: the contract exposes no mint, owner, pause, blacklist, freeze or upgrade
///         path, so the supply can never grow and no privileged hand can move or freeze a holder's
///         balance. Transfers are untaxed and unrestricted, so every launch flow (factory to
///         distributor, distributor to claimant, pool seed, buys and sells) moves exactly what it
///         says.
/// @dev The contract identifier is `BitcornToken` (12 characters); the launch records it under that
///      Solidity name. The token's `name()` is "bitcorn" and its `symbol()` is "BITCORN".
///      The constructor takes no arguments and calls no other contract, so it deploys on an empty
///      chain and needs no constructor arguments in the launch manifest.
contract BitcornToken is ERC20 {
    /// @notice The token's human-readable name.
    string public constant TOKEN_NAME = "bitcorn";

    /// @notice The token's ticker symbol.
    string public constant TOKEN_SYMBOL = "BITCORN";

    /// @notice Number of decimals, the ERC-20 default.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 * 10**18. Minted once; never grows.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints the entire fixed supply to the deployer.
    /// @dev At launch the deployer is the ProjectFactory, which then pays the supply out: the
    ///      swarm's share to the MerkleDistributor, the pool share into the Uniswap v4 pool, and
    ///      the remainder to the requester's address. The token never holds any of it itself.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}

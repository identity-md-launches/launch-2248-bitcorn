// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BitcornToken} from "../src/BitcornToken.sol";

/// @notice Deploys the token so that the constructor's `msg.sender` is a contract, as at launch.
contract BitcornDeployer {
    function deploy() external returns (BitcornToken token) {
        token = new BitcornToken();
    }

    function move(BitcornToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Drives the token with random transfers, approvals and transferFroms between a fixed set of
///         actors (the deployer included), and tracks in ghost storage what every balance and
///         allowance must be. Calls that the ERC-20 must refuse are attempted too, and must leave
///         everything unchanged.
contract BitcornHandler is Test {
    BitcornToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public transfers;
    uint256 public transferFroms;
    uint256 public approvals;
    uint256 public refusals;
    /// @dev Set if a call the ERC-20 must refuse went through, or one it must accept reverted.
    bool public unexpected;

    constructor(BitcornToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        actors.push(address(0xD157));
        actors.push(address(0x900D));
        ghostBalance[deployer] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        amount = _bound(amount, 0, held);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) unexpected = true;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            transfers++;
        } catch {
            unexpected = true;
        }
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 amount = held + _bound(excess, 1, type(uint256).max - held);
        vm.prank(from);
        try token.transfer(to, amount) {
            unexpected = true;
        } catch (bytes memory reason) {
            if (
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
                    )
            ) unexpected = true;
            refusals++;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = _bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            unexpected = true;
        } catch {
            refusals++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Mostly sensible amounts, sometimes the infinite allowance.
        if (amount % 5 == 0) amount = type(uint256).max;
        else amount = _bound(amount, 0, token.totalSupply());
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) unexpected = true;
            ghostAllowance[owner][spender] = amount;
            approvals++;
        } catch {
            unexpected = true;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 held = ghostBalance[owner];
        uint256 ceiling = allowed < held ? allowed : held;
        amount = _bound(amount, 0, ceiling);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) unexpected = true;
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            transferFroms++;
        } catch {
            unexpected = true;
        }
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return;
        uint256 amount = allowed + _bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            unexpected = true;
        } catch (bytes memory reason) {
            if (
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(
                            IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount
                        )
                    )
            ) unexpected = true;
            refusals++;
        }
    }

    function sumOfBalances() external view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
    }
}

contract BitcornTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    BitcornDeployer internal deployer;
    BitcornToken internal token;
    BitcornHandler internal handler;

    function setUp() public {
        deployer = new BitcornDeployer();
        token = deployer.deploy();
        handler = new BitcornHandler(token, address(deployer));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = BitcornHandler.transfer.selector;
        selectors[1] = BitcornHandler.transferTooMuch.selector;
        selectors[2] = BitcornHandler.transferToZero.selector;
        selectors[3] = BitcornHandler.approve.selector;
        selectors[4] = BitcornHandler.transferFrom.selector;
        selectors[5] = BitcornHandler.transferFromOverAllowance.selector;
        // Weight the value-moving call twice.
        selectors[6] = BitcornHandler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "the fixed supply changed");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_actorsHoldTheWholeSupply() public view {
        assertEq(handler.sumOfBalances(), SUPPLY, "balances do not sum to the supply");
        assertEq(token.balanceOf(address(token)), 0, "the token holds some of its own supply");
        assertEq(token.balanceOf(address(handler)), 0, "the handler acquired tokens");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesAndAllowancesMatchGhosts() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "a balance drifted from its expected value");
            for (uint256 j; j < n; ++j) {
                address s = handler.actors(j);
                assertEq(token.allowance(a, s), handler.ghostAllowance(a, s), "an allowance drifted");
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_everyCallBehavedAsSpecified() public view {
        assertFalse(handler.unexpected(), "a call that must be refused succeeded, or one that must succeed failed");
    }

    /// @dev Guards against a vacuous campaign: every run must actually have moved value.
    function afterInvariant() public view {
        assertGt(handler.transfers() + handler.transferFroms(), 0, "no value-moving call ran");
    }
}

/// @notice Edge cases the main suite does not pin: self-transfers, the full supply, zero amounts,
///         error precedence and allowance overwrites.
contract BitcornTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    BitcornDeployer internal deployer;
    BitcornToken internal token;

    function setUp() public {
        deployer = new BitcornDeployer();
        token = deployer.deploy();
    }

    function test_wholeSupplyMovesInOneTransfer() public {
        assertTrue(deployer.move(token, ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(address(deployer)), 0);
        vm.prank(address(deployer));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(ALICE, 1);
    }

    function test_oneWeiOverTheSupplyReverts() public {
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_maxUintTransferReverts() public {
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(ALICE, type(uint256).max);
    }

    function testFuzz_selfTransferKeepsBalance(uint256 amount) public {
        deployer.move(token, ALICE, 1_000 ether);
        amount = _bound(amount, 0, 1_000 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), 1_000 ether, "a self-transfer changed the balance");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferAboveBalanceReverts() public {
        deployer.move(token, ALICE, 5);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5, 6));
        token.transfer(ALICE, 6);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(ALICE);
        token.approve(BOB, 10 ether);
        token.approve(BOB, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), 3 ether);
        vm.prank(ALICE);
        token.approve(BOB, 0);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_revokedApprovalBlocksTransferFrom() public {
        deployer.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1 ether));
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_allowanceAboveBalanceStillChecksBalance() public {
        deployer.move(token, ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, 100 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 2 ether));
        token.transferFrom(ALICE, CAROL, 2 ether);
        // The revert rolled back the allowance spend as well.
        assertEq(token.allowance(ALICE, BOB), 100 ether);
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function test_transferFromToZeroAddressReverts() public {
        deployer.move(token, ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 1 ether);
        assertEq(token.allowance(ALICE, BOB), 1 ether);
    }

    function test_transferFromZeroAddressOwnerReverts() public {
        // OpenZeppelin spends (re-approves) the allowance before it checks the sender, so the
        // zero-address owner is refused as an approver first.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), BOB, 0);
    }

    function test_zeroTransferFromNeedsNoAllowanceAndMovesNothing() public {
        deployer.move(token, ALICE, 1 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_deployerHasNoAllowanceOverHolders() public {
        deployer.move(token, ALICE, 1 ether);
        assertEq(token.allowance(ALICE, address(deployer)), 0);
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(deployer), 0, 1)
        );
        token.transferFrom(ALICE, address(deployer), 1);
    }

    function test_tokenContractCanReceiveAndTokensAreThenStuck() public {
        // Plain ERC-20: nothing stops a holder sending tokens to the token contract, and nothing
        // can retrieve them afterwards. Supply is unchanged; the tokens are simply unspendable.
        deployer.move(token, address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_twoHopTransferIsExact(uint256 a, uint256 b) public {
        a = _bound(a, 0, SUPPLY);
        b = _bound(b, 0, a);
        deployer.move(token, ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        assertEq(token.balanceOf(ALICE), a - b);
        assertEq(token.balanceOf(BOB), b);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - a);
        assertEq(token.balanceOf(address(deployer)) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
    }
}

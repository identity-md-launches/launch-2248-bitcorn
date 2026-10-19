// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BitcornToken} from "../src/BitcornToken.sol";

/// @notice Stands in for the ProjectFactory: deploys the token with CREATE2 so that `msg.sender` in
///         the constructor is this contract, exactly as at launch, and then pays the supply out.
contract FactoryStub {
    function deploy(bytes32 salt) external returns (BitcornToken token) {
        token = new BitcornToken{salt: salt}();
    }

    function move(BitcornToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract BitcornTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 6_000;

    address internal constant REMAINDER_TO = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    FactoryStub internal factory;
    BitcornToken internal token;

    function setUp() public {
        factory = new FactoryStub();
        token = factory.deploy(bytes32(uint256(1)));
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "bitcorn");
        assertEq(token.symbol(), "BITCORN");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "bitcorn");
        assertEq(token.TOKEN_SYMBOL(), "BITCORN");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(token)), 0, "the token holds some of its own supply");
        assertEq(token.balanceOf(address(this)), 0, "the test holds some of the supply");
    }

    function test_constructorEmitsSingleMintTransfer() public {
        FactoryStub other = new FactoryStub();
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), address(other), SUPPLY);
        BitcornToken fresh = other.deploy(bytes32(uint256(2)));
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(other)), SUPPLY);
    }

    function test_deploysToPredictableCreate2Address() public {
        bytes32 salt = bytes32(uint256(7));
        bytes32 initHash = keccak256(type(BitcornToken).creationCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))));
        BitcornToken fresh = factory.deploy(salt);
        assertEq(address(fresh), predicted, "CREATE2 address differs from prediction");
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows move exactly what they say
    // ---------------------------------------------------------------------------------------------

    function test_launchFlowsArriveWholeAndPreserveSupply() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(token, DISTRIBUTOR, swarm), "distributor transfer returned false");
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm), "claim transfer returned false");
        assertEq(token.balanceOf(CLAIMANT), swarm, "claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "distributor kept something back");

        // The pool seed and the remainder are plain transfers from the factory as well.
        address poolManager = address(0x900D);
        assertTrue(factory.move(token, poolManager, pool), "pool transfer returned false");
        assertEq(token.balanceOf(poolManager), pool, "pool share arrived short");
        assertTrue(factory.move(token, REMAINDER_TO, remainder), "remainder transfer returned false");
        assertEq(token.balanceOf(REMAINDER_TO), remainder, "remainder arrived short");

        assertEq(token.balanceOf(address(factory)), 0, "factory did not pay everything out");
        assertEq(token.totalSupply(), SUPPLY, "launch flows changed the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Ordinary ERC-20 behaviour: success paths
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesBalanceAndEmits() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, BOB, 40 ether);
        assertTrue(token.transfer(BOB, 40 ether));
        assertEq(token.balanceOf(ALICE), 60 ether);
        assertEq(token.balanceOf(BOB), 40 ether);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_approveAndTransferFrom() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(ALICE, BOB, 70 ether);
        assertTrue(token.approve(BOB, 70 ether));
        assertEq(token.allowance(ALICE, BOB), 70 ether);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CLAIMANT, 50 ether));
        assertEq(token.balanceOf(ALICE), 50 ether);
        assertEq(token.balanceOf(CLAIMANT), 50 ether);
        assertEq(token.allowance(ALICE, BOB), 20 ether, "allowance not decremented");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CLAIMANT, 30 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Ordinary ERC-20 behaviour: failure paths
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transfer(BOB, 11 ether);
    }

    function test_transferRevertsToZeroAddress() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function test_transferFromRevertsOnInsufficientAllowance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 5 ether, 6 ether));
        token.transferFrom(ALICE, CLAIMANT, 6 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes or seizes
    // ---------------------------------------------------------------------------------------------

    function test_noCallIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected function exists: ", signatures[i]));
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected function exists for deployer: ", signatures[i]));
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(token, ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected function exists: ", signatures[i]));
        }
        vm.prank(address(factory));
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, ALICE, address(factory), 1));
        assertFalse(moved, "deployer pulled tokens without allowance");
        assertEq(token.balanceOf(ALICE), held, "a privileged call moved the holder's balance");
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_hasNoOwnerAndNoReceiveFallback() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "token exposes owner()");
        assertEq(ret.length, 0);
        (ok,) = address(token).call{value: 0}("");
        assertFalse(ok, "token accepts empty calldata");
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepts ether");
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness of transfers
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferIsExactAndConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(factory.move(token, to, amount));
        assertEq(token.balanceOf(to), amount, "transfer arrived short or long");
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        factory.move(token, ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(BOB, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        factory.move(token, ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(BOB, allowed);
        vm.prank(BOB);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowed, amount)
            );
            token.transferFrom(ALICE, CLAIMANT, amount);
        } else {
            assertTrue(token.transferFrom(ALICE, CLAIMANT, amount));
            assertEq(token.balanceOf(CLAIMANT), amount);
            assertEq(token.allowance(ALICE, BOB), allowed - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}

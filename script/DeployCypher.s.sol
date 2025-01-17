pragma solidity 0.8.19;

import {Script} from "@forge-std/Script.sol";

import "@forge-std/Test.sol";

import {CypherAutoLoad} from "@protocol/cypher/CypherAutoLoad.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {ERC4626RateLimitedAllowance} from "@protocol/cypher/ERC4626RateLimitedAllowance.sol";

contract DeployCypher is Script, Test {
    function run() public {
        Addresses addresses = new Addresses();
        vm.startBroadcast();

        CypherAutoLoad autoLoad = deployAutoLoad(addresses);

        ERC4626RateLimitedAllowance rateLimitedAllowance = deployERC4626RateLimitedAllowance(
                addresses,
                address(autoLoad)
            );

        vm.stopBroadcast();

        addresses.addAddress("CHYPHER_AUTO_LOAD", address(autoLoad));

        addresses.addAddress(
            "CYPHER_ERC4626_RATE_LIMITED_ALLOWANCE",
            address(rateLimitedAllowance)
        );

        validate(addresses, autoLoad, rateLimitedAllowance);

        addresses.printAddresses();
    }

    function deployAutoLoad(
        Addresses addresses
    ) public returns (CypherAutoLoad autoLoad) {
        address executor = addresses.getAddress("CYPHER_EXECUTOR");
        address beneficiary = addresses.getAddress("CYPHER_BENEFICIARY");

        autoLoad = new CypherAutoLoad(executor, beneficiary);
    }

    function deployERC4626RateLimitedAllowance(
        Addresses addresses,
        address autoLoad
    ) public returns (ERC4626RateLimitedAllowance rateLimitedAllowance) {
        rateLimitedAllowance = new ERC4626RateLimitedAllowance(
            address(addresses.getAddress("SECURITY_COUNCIL")),
            autoLoad
        );
    }

    function validate(
        Addresses addresses,
        CypherAutoLoad autoLoad,
        ERC4626RateLimitedAllowance limitedAllowance
    ) public view {
        assertEq(
            address(autoLoad),
            addresses.getAddress("CHYPHER_AUTO_LOAD"),
            "CypherAutoLoad not deployed"
        );
        assertEq(
            address(limitedAllowance),
            addresses.getAddress("CYPHER_ERC4626_RATE_LIMITED_ALLOWANCE")
        );

        assertEq(
            autoLoad.beneficiary(),
            addresses.getAddress("CYPHER_BENEFICIARY"),
            "Wrong beneficiary"
        );

        assertTrue(
            autoLoad.hasRole(
                autoLoad.EXECUTIONER_ROLE(),
                addresses.getAddress("CYPHER_EXECUTOR")
            ),
            "Wrong executor"
        );

        assertTrue(
            autoLoad.hasRole(
                autoLoad.DEFAULT_ADMIN_ROLE(),
                addresses.getAddress("CYPHER_EXECUTOR")
            ),
            "Wrong admin"
        );

        assertEq(
            limitedAllowance.spender(),
            address(autoLoad),
            "Wrong spender"
        );

        assertEq(
            limitedAllowance.owner(),
            address(addresses.getAddress("SECURITY_COUNCIL")),
            "Wrong owner"
        );
    }
}

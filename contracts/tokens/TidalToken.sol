// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// This token is owned by Timelock.
contract TidalToken is ERC20("Tidal Token", "TIDAL") {

    constructor() public {
        _mint(msg.sender, 2e28);  // 20 billion, 18 decimals
    }

}

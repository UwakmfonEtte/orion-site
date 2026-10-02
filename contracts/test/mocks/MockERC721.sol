// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Bare-bones ERC-721 for exercising OrionTreasury in tests.
contract MockERC721 is ERC721 {
    uint256 public totalMinted;

    constructor() ERC721("MockOrion", "MORI") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
        totalMinted += 1;
    }

    /// @dev Lets tests set circulating supply directly without minting N tokens.
    function setTotalMinted(uint256 n) external {
        totalMinted = n;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title OrionNFT
 * @notice The 1,555-supply Orion mint. Allowlist-gated by a Merkle root (the
 *         waitlist/vouch decision already happens off-chain in Postgres;
 *         this just proves membership cheaply on-chain), one mint per
 *         address, and every wei paid is forwarded straight to the
 *         OrionTreasury - this contract never holds mint proceeds itself.
 *
 * mintPriceWei is owner-settable rather than computed from an on-chain price
 * feed: $12 is a USD figure, and a Chainlink feed is one more paid
 * dependency and one more thing that can be stale or wrong. The multisig
 * updates it to track ETH/USD, the same way the site already shows a
 * client-side quote via /api/eth-price.
 */
contract OrionNFT is ERC721, Ownable, ReentrancyGuard, Pausable {
    uint256 public constant MAX_SUPPLY = 1555;

    address payable public immutable treasury;

    uint256 public mintPriceWei;
    bytes32 public merkleRoot;
    uint256 public totalMinted;
    string private _baseTokenURI;

    mapping(address => bool) public hasMinted;

    event Minted(address indexed to, uint256 indexed tokenId, uint256 pricePaid);
    event MintPriceUpdated(uint256 newPriceWei);
    event MerkleRootUpdated(bytes32 newRoot);
    event BaseURIUpdated(string newBaseURI);

    constructor(address initialOwner, address payable treasuryAddress, uint256 initialMintPriceWei)
        ERC721("Orion", "ORION")
        Ownable(initialOwner)
    {
        require(treasuryAddress != address(0), "zero treasury");
        treasury = treasuryAddress;
        mintPriceWei = initialMintPriceWei;
    }

    // ---------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------

    /// @dev Settable only before the first mint - meant for one calibration
    ///      right before launch (the $12-in-ETH conversion at that moment),
    ///      never as an ongoing adjustment once the sale is live. The
    ///      treasury's redemption math assumes every mint paid the same
    ///      price; changing it mid-sale would let whoever mints after a drop
    ///      redeem for more than they paid, out of earlier minters' deposits.
    function setMintPriceWei(uint256 newPriceWei) external onlyOwner {
        require(totalMinted == 0, "mint already started");
        mintPriceWei = newPriceWei;
        emit MintPriceUpdated(newPriceWei);
    }

    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------

    /**
     * @param proof Merkle proof that msg.sender is on the approved list.
     *
     * Overpayment is refunded, not kept - mintPriceWei can lag the ETH/USD
     * rate between the price being set and the transaction landing, and
     * silently pocketing the difference would be the wrong default.
     */
    function mint(bytes32[] calldata proof) external payable nonReentrant whenNotPaused {
        require(totalMinted < MAX_SUPPLY, "sold out");
        require(!hasMinted[msg.sender], "already minted");
        require(merkleRoot != bytes32(0), "allowlist not set");

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "not on allowlist");
        require(msg.value >= mintPriceWei, "insufficient payment");

        hasMinted[msg.sender] = true;
        uint256 tokenId = totalMinted + 1; // token IDs run 1..1555, matching the metadata files
        totalMinted += 1;

        // All value transfers happen before _safeMint's onERC721Received hook
        // can hand control to attacker-supplied code. Minting last means a
        // reentering call sees fully-settled state (treasury funded, refund
        // sent, totalMinted bumped) instead of a window where the token is
        // minted but the treasury hasn't been paid yet.
        uint256 refund = msg.value - mintPriceWei;

        (bool sentToTreasury, ) = treasury.call{value: mintPriceWei}("");
        require(sentToTreasury, "treasury transfer failed");

        if (refund > 0) {
            (bool sentRefund, ) = msg.sender.call{value: refund}("");
            require(sentRefund, "refund failed");
        }

        _safeMint(msg.sender, tokenId);

        emit Minted(msg.sender, tokenId, mintPriceWei);
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }

    /// @dev OpenZeppelin's Ownable ships a one-click renounceOwnership(). If
    ///      called before setMerkleRoot(), the mint can never open and there
    ///      is no other way to set it - disabled rather than relied on never
    ///      being clicked by accident in a Safe UI.
    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}

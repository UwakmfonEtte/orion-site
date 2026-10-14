// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title OrionTestNFT
 * @notice Testnet stand-in for OrionNFT: same money flow, none of the
 *         allowlist. Public mint with a supply and a per-wallet cap fixed at
 *         construction (150 and 2 on the public testnet), so anyone with a
 *         faucet drip can walk the whole mint -> treasury -> redeem loop.
 *
 * Everything that matters to the treasury is identical to the real contract:
 * every wei of the price goes straight to the treasury before the token is
 * minted, overpayment is refunded, the price is locked once the first token
 * exists, ownership can't be renounced, and totalMinted() is exposed so the
 * treasury can size redemptions against real circulating supply.
 */
/// @dev The mint must pay a treasury that has wired THIS contract in. Otherwise the
///      treasury treats the NFT as a stranger and quietly reroutes the mint
///      money to its donation sink, leaving holders with no backing.
interface ITreasuryWiredCheckOrionTestNFT {
    function nftContract() external view returns (address);
    function royaltySplitter() external view returns (address);
}

contract OrionTestNFT is ERC721, ERC2981, Ownable2Step, ReentrancyGuard, Pausable {
    uint256 public immutable MAX_SUPPLY;
    uint256 public immutable MAX_PER_WALLET;

    address payable public immutable TREASURY;

    uint256 public mintPriceWei;
    uint256 public totalMinted;
    string private _baseTokenURI;

    mapping(address => uint256) public mintedBy;
    bool public closed;
    uint96 public constant ROYALTY_BPS = 1000;          // 10%

    event MintClosed();
    event Minted(address indexed to, uint256 firstTokenId, uint256 quantity, uint256 pricePaid);
    event MintPriceUpdated(uint256 newPriceWei);
    event BaseURIUpdated(string newBaseURI);

    constructor(
        address initialOwner,
        address payable treasuryAddress,
        uint256 initialMintPriceWei,
        uint256 maxSupply,
        uint256 maxPerWallet
    ) ERC721("Orion Testnet", "ORIONT") Ownable(initialOwner) {
        require(treasuryAddress != address(0), "zero treasury");
        require(maxSupply > 0 && maxPerWallet > 0, "bad limits");
        MAX_SUPPLY = maxSupply;
        MAX_PER_WALLET = maxPerWallet;
        TREASURY = treasuryAddress;
        mintPriceWei = initialMintPriceWei;
    }

    function setMintPriceWei(uint256 newPriceWei) external onlyOwner {
        require(totalMinted == 0, "mint already started");
        mintPriceWei = newPriceWei;
        emit MintPriceUpdated(newPriceWei);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /// @notice Irreversibly end the mint. Redemption, loans and the rest of
    ///         the treasury open only once the mint is closed (here, or by
    ///         selling out).
    /// @notice Secondary-sale royalty: 10%, paid to the royalty splitter. It can
    ///         be pointed at its receiver until the mint closes, then it is fixed.
    ///         Marketplaces read this (ERC-2981); whether they honor it is up to
    ///         each marketplace, and nothing here can force a sale to pay it.
    function setRoyaltyReceiver(address receiver) external onlyOwner {
        require(!mintClosed(), "mint is closed");
        require(receiver != address(0), "zero address");
        // The treasury must have this same splitter wired. Both settings lock when the
        // mint closes, and a mismatch would strand or divert the backing share.
        require(ITreasuryWiredCheckOrionTestNFT(TREASURY).royaltySplitter() == receiver, "treasury has a different splitter");
        _setDefaultRoyalty(receiver, ROYALTY_BPS);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }

    function closeMint() external onlyOwner {
        closed = true;
        emit MintClosed();
    }

    /// @notice True once minting is over: closed by the owner, or sold out.
    function mintClosed() public view returns (bool) {
        return closed || totalMinted >= MAX_SUPPLY;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Mint `quantity` Orions (up to MAX_PER_WALLET per wallet in total).
    function mint(uint256 quantity) external payable nonReentrant whenNotPaused {
        require(!closed, "mint is closed");
        require(quantity > 0, "quantity is zero");
        require(mintedBy[msg.sender] + quantity <= MAX_PER_WALLET, "wallet limit reached");
        require(totalMinted + quantity <= MAX_SUPPLY, "not enough left");

        uint256 cost = mintPriceWei * quantity;
        require(msg.value >= cost, "insufficient payment");
        require(ITreasuryWiredCheckOrionTestNFT(TREASURY).nftContract() == address(this), "treasury not wired");

        uint256 firstId = totalMinted + 1;   // token IDs run 1..MAX_SUPPLY
        mintedBy[msg.sender] += quantity;
        totalMinted += quantity;

        // Money moves before any token reaches the buyer, so a contract
        // buyer's onERC721Received hook sees fully-settled state.
        (bool toTreasury, ) = TREASURY.call{value: cost}("");
        require(toTreasury, "treasury transfer failed");

        uint256 refund = msg.value - cost;
        if (refund > 0) {
            (bool refunded, ) = msg.sender.call{value: refund}("");
            require(refunded, "refund failed");
        }

        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(msg.sender, firstId + i);
        }

        emit Minted(msg.sender, firstId, quantity, cost);
    }

    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}

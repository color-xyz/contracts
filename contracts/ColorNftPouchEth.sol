// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ColorNftPouchEth is IERC721Receiver, Ownable, ReentrancyGuard {
    IERC721 public colorNft;

    struct NFT {
        address owner;
        uint256 boost;
        uint256 rewards;
        uint256 lastPlayedTime;
    }
    mapping(uint256 => NFT) public nfts;
    mapping(address => uint256[]) ownedIds;
    mapping(address => bool) public authorizedDistributors;
    uint256 public totalBoost;

    event RewardsClaimed(uint256 indexed _id, uint256 indexed _amount);
    event DepositBoost(uint256 indexed _id, uint256 indexed _amount);
    event NftStaked(uint256 indexed _id);
    event NftUnstaked(uint256 indexed _id);
    event RewardsDistributed(uint256[] indexed _ids, uint256[] indexed _amounts);
    event BoostsWithdrawn(uint256 indexed _amount);

    constructor(IERC721 _nftContract) Ownable(msg.sender) {
        colorNft = _nftContract;
    }

    function getOwnedIds(address _owner)
    external view returns (uint256[] memory) {
        require(_owner != address(0), "Invalid address");
        return ownedIds[_owner];
    }

    function getNftSupply()
    external view returns(uint256) {
        return colorNft.balanceOf(address(this));
    }

    function setAuthorizedDistributor(address distributor, bool authorized) 
    external onlyOwner {
        require(distributor != address(0), "Invalid address");
        authorizedDistributors[distributor] = authorized;
    }

    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data)
    external returns (bytes4) {
        require(msg.sender == address(colorNft), "Can only receive ColorNft");
        require(ownedIds[_from].length < 5, "Max 5 NFTs per address");

        nfts[_tokenId].owner = _from;
        ownedIds[_from].push(_tokenId);

        emit NftStaked(_tokenId);
        return this.onERC721Received.selector;
    }

    function unstakeNft(uint256 _tokenId)
    external {
        NFT memory nft = nfts[_tokenId];
        require(nft.owner == msg.sender, "Only the owner of the NFT can unstake");
        require(nft.rewards == 0, "Please withdraw rewards first");

        colorNft.transferFrom(address(this), msg.sender, _tokenId);

        nft.owner = address(0);
        uint256[] storage ids = ownedIds[msg.sender];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == _tokenId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }

        nfts[_tokenId] = nft;

        emit NftUnstaked(_tokenId);
    }

    function depositBoost(uint256 _tokenId)
    external payable {
        require(msg.value > 0, "Incoming eth amount must be positive");
        NFT memory nft = nfts[_tokenId];
        require(nft.owner == msg.sender, "Only the owner of the NFT can deposit boost");

        nft.boost += msg.value;
        nfts[_tokenId] = nft;
        totalBoost += msg.value;

        emit DepositBoost(_tokenId, msg.value);
    }

    function withdrawBoosts()
    external onlyOwner nonReentrant {
        require(totalBoost > 0, "No boosts to withdraw");
        uint256 amount = totalBoost;
        totalBoost = 0;

        (bool success, ) = owner().call{value: amount}("");
        require(success, "Withdraw failed");

        emit BoostsWithdrawn(amount);
    }

    function claimRewards(uint256 _tokenId)
    external nonReentrant {
        NFT memory nft = nfts[_tokenId];
        uint256 rewards = nft.rewards;

        require(nft.owner == msg.sender, "Only the owner of the NFT can claim rewards");
        require(rewards > 0, "No rewards to claim");

        (bool success, ) = msg.sender.call{value: rewards}("");
        require(success, "Eth not arrived");

        nft.rewards -= rewards;
        nfts[_tokenId] = nft;

        emit RewardsClaimed(_tokenId, rewards);
    }

    function distributeRewards(uint256[] calldata _ids, uint256[] calldata _amounts)
    external {
        require(authorizedDistributors[msg.sender], "Not authorized");
        require(_ids.length == _amounts.length, "Length of ids and amounts must match");
        for (uint256 i = 0; i < _ids.length; i++) {
            nfts[_ids[i]].rewards += _amounts[i];
        }

        emit RewardsDistributed(_ids, _amounts);
    }

    function deposit()
    external payable {
        require(msg.value > 0, "Not enough eth sent");
    }

    receive() external payable  { }
}

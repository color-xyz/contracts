// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ColorNftPouchEth is IERC721Receiver, Ownable, ReentrancyGuard {
    // Custom Errors
    error InvalidAddress();
    error MaxNftsReached();
    error OnlyColorNftAllowed();
    error OnlyNftOwner();
    error WithdrawRewardsFirst();
    error NoRewardsToClaim();
    error TransferFailed();
    error NotAuthorized();
    error ArrayLengthMismatch();
    error NoBoostsToWithdraw();
    error InsufficientPayment();
    
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
    event AuthorizedDistributorUpdated(address indexed distributor, bool authorized);

    constructor(IERC721 _nftContract) Ownable(msg.sender) {
        colorNft = _nftContract;
    }

    function getOwnedIds(address _owner)
    external view returns (uint256[] memory) {
        if(_owner == address(0)) revert InvalidAddress();
        return ownedIds[_owner];
    }

    function getNftSupply()
    external view returns(uint256) {
        return colorNft.balanceOf(address(this));
    }

    function setAuthorizedDistributor(address distributor, bool authorized) 
    external onlyOwner {
        if(distributor == address(0)) revert InvalidAddress();
        authorizedDistributors[distributor] = authorized;
        emit AuthorizedDistributorUpdated(distributor, authorized);
    }

    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data)
    external returns (bytes4) {
        if(msg.sender != address(colorNft)) revert OnlyColorNftAllowed();
        if(ownedIds[_from].length >= 5) revert MaxNftsReached();

        nfts[_tokenId].owner = _from;
        ownedIds[_from].push(_tokenId);

        emit NftStaked(_tokenId);
        return this.onERC721Received.selector;
    }

    function unstakeNft(uint256 _tokenId)
    external {
        NFT memory nft = nfts[_tokenId];
        if(nft.owner != msg.sender) revert OnlyNftOwner();
        if(nft.rewards != 0) revert WithdrawRewardsFirst();

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
        if(msg.value == 0) revert InsufficientPayment();
        NFT memory nft = nfts[_tokenId];
        if(nft.owner != msg.sender) revert OnlyNftOwner();

        nft.boost += msg.value;
        nfts[_tokenId] = nft;
        totalBoost += msg.value;

        emit DepositBoost(_tokenId, msg.value);
    }

    function withdrawBoosts()
    external onlyOwner nonReentrant {
        if(totalBoost == 0) revert NoBoostsToWithdraw();
        uint256 amount = totalBoost;
        totalBoost = 0;

        (bool success, ) = owner().call{value: amount}("");
        if(!success) revert TransferFailed();

        emit BoostsWithdrawn(amount);
    }

    function claimRewards(uint256 _tokenId)
    external nonReentrant {
        NFT memory nft = nfts[_tokenId];
        uint256 rewards = nft.rewards;

        if(nft.owner != msg.sender) revert OnlyNftOwner();
        if(rewards == 0) revert NoRewardsToClaim();

        (bool success, ) = msg.sender.call{value: rewards}("");
        if(!success) revert TransferFailed();

        nft.rewards -= rewards;
        nfts[_tokenId] = nft;

        emit RewardsClaimed(_tokenId, rewards);
    }

    function distributeRewards(uint256[] calldata _ids, uint256[] calldata _amounts)
    external {
        if(!authorizedDistributors[msg.sender]) revert NotAuthorized();
        if(_ids.length != _amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < _ids.length; i++) {
            nfts[_ids[i]].rewards += _amounts[i];
        }

        emit RewardsDistributed(_ids, _amounts);
    }

    function deposit()
    external payable {
        if(msg.value == 0) revert InsufficientPayment();
    }

    receive() external payable  { }
}

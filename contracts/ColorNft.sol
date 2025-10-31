// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC721Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


contract ColorNft is IERC721, IERC721Metadata, Ownable, ReentrancyGuard {
    string public constant name = "Color";
    string public constant symbol = "COL";
    uint256 public nextId;
    uint256 public price;

    struct NFT {
        address owner;
        string uri;
        string name;
    }

    mapping(uint256 => NFT) nfts;
    mapping(address => uint256[]) ownedIds;
    mapping(address => uint256) balance;
    mapping(uint256 => address) approved;
    mapping(address => mapping(address => bool)) approvedForAll;
    mapping(address => uint256) freeMintBalance;
    mapping(address => uint256) nonces; 

    constructor(uint256 _price) Ownable(msg.sender) {
        price = _price;
    }

    function setPrice(uint256 _price) onlyOwner external {
        price = _price;
    }

    function mint(string memory _name, string memory _uri, bytes calldata _signature) external nonReentrant payable returns (uint256) {
        require(msg.value >= price, "Not enough eth sent");
        bytes memory message = abi.encodePacked(
            bytes("Mint"),
            address(msg.sender),
            bytes(_name),
            bytes(_uri),
            bytes32(nonces[msg.sender])
        );
        require(_verify(message, _signature), "Not verified");

        NFT memory nft = NFT(msg.sender, _uri, _name);
        nfts[nextId] = nft;
        balance[msg.sender]++;
        ownedIds[msg.sender].push(nextId);
        
        nonces[msg.sender]++;

        emit Transfer(address(0), msg.sender, nextId);

        return nextId++;
    }

    function freeMint(string memory _name, string memory _uri, bytes calldata _signature) external nonReentrant returns (uint256) {
        require(freeMintBalance[msg.sender] > 0, "No free mints available");
        bytes memory message = abi.encodePacked(
            bytes("Mint"),
            address(msg.sender),
            bytes(_name),
            bytes(_uri),
            bytes32(nonces[msg.sender])
        );
        require(_verify(message, _signature), "Not verified");

        NFT memory nft = NFT(msg.sender, _uri, _name);
        nfts[nextId] = nft;
        balance[msg.sender]++;
        ownedIds[msg.sender].push(nextId);

        freeMintBalance[msg.sender]--;
        nonces[msg.sender]++;

        emit Transfer(address(0), msg.sender, nextId);

        return nextId++;
    }

    function withdraw() external onlyOwner payable {

        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "Withdraw was not successful");
    }

    function ownerOf(uint256 _id) external view returns (address) {
        require(_id < nextId, "Invalid token id");
        return nfts[_id].owner;
    }

    function getOwnedIds(address _owner) external view returns (uint256[] memory) {
        require(_owner != address(0), "Invalid address");
        return ownedIds[_owner];
    }

    function balanceOf(address _owner) external view returns (uint256) {
        require(_owner != address(0), "Invalid address");
        return balance[_owner];
    }

    function getFreeMintBalance(address _address) external view returns (uint256) {
        require(_address != address(0), "Invalid address");
        return freeMintBalance[_address];
    }

    function getNonce(address user)
    external view returns (uint256) {
        return nonces[user];
    }    

    function provideFreeMint(address _address) external onlyOwner {
        require(_address != address(0), "Invalid address");
        freeMintBalance[_address]++;
    }

    function tokenURI(uint256 _id) external view returns (string memory) {
        require(_id < nextId, "Invalid token");
        return nfts[_id].uri;
    }

    function tokenName(uint256 _id) external view returns (string memory) {
        require(_id < nextId, "Invalid token");
        return nfts[_id].name;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return (interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId);
    }

    function getApproved(uint256 _tokenId) external view returns (address) {
        require(_tokenId < nextId, "Invalid token");
        return approved[_tokenId];
    }

    function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
        require(_owner != address(0), "Invalid address");
        require(_operator != address(0), "Invalid address");
        return approvedForAll[_owner][_operator];
    }

    function approve(address _approved, uint256 _tokenId) external {
        require(nfts[_tokenId].owner == msg.sender || approvedForAll[nfts[_tokenId].owner][msg.sender], "Not approved!");

        approved[_tokenId] = _approved;

        emit Approval(msg.sender, _approved, _tokenId);
    }

    function setApprovalForAll(address _operator, bool _approved) external {
        require(_operator != address(0), "Invalid address!");
        approvedForAll[msg.sender][_operator] = _approved;

        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) public {
        require(_to != address(0), "Invalid recipient");
        require(_tokenId < nextId, "Invalid token");
        require(nfts[_tokenId].owner == _from, "Token is not owned by source address");
        if (msg.sender != _from && msg.sender != approved[_tokenId]) {
            require(approvedForAll[_from][msg.sender], "Not approved!");
        }

        nfts[_tokenId].owner = _to;
        balance[_from]--;
        balance[_to]++;
        uint256[] storage ids = ownedIds[_from];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == _tokenId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }
        ownedIds[_to].push(_tokenId);

        approved[_tokenId] = address(0);

        emit Transfer(_from, _to, _tokenId);
    }

    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId,
        bytes memory _data
    ) public {
        transferFrom(_from, _to, _tokenId);
        if (_to.code.length > 0) {
            try
                IERC721Receiver(_to).onERC721Received(
                    msg.sender,
                    _from,
                    _tokenId,
                    _data
                )
            returns (bytes4 selector) {
                require(
                    selector == IERC721Receiver.onERC721Received.selector,
                    "Invalid receiver"
                );
            } catch Error(string memory reason) {
                revert(reason);
            }
        }
    }

    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId
    ) external {
        safeTransferFrom(_from, _to, _tokenId, "");
    }

    function _verify(bytes memory _message, bytes memory _signature) internal view returns(bool) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(_message);
        address signer = ECDSA.recover(signedHash, _signature);

        return signer == address(owner());
    }
}




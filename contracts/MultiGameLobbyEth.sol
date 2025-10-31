// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ColorNftPouchEth.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MultiGameLobbyEth is Ownable, ReentrancyGuard {
    struct Room {
        uint256 entryPrice;
        uint256 maxPlayerCount;
        uint256 gameStartTime;
        uint256 creationTime;
        uint256 gameId;
        address owner;
        address[] players;
    }

    ColorNftPouchEth public colorNftPouch;
    uint8 public maxPlayers;
    uint256 public nextRoomId;
    uint256 public feeBalance;
    // Tracks up to which room withdrawals have been processed
    uint256 public lastWithdrawnRoomId;

    mapping(uint256 => Room) public rooms;
    mapping(address => uint256) public nonces; 

    event RoomCreated(uint256 indexed roomId, uint256 entryPrice, uint256 maxPlayerCount);
    event GameStarted(uint256 indexed roomId, uint256 indexed gameId);
    event PlayerJoined(uint256 indexed roomId, address indexed player);
    event PlayerLeft(uint256 indexed roomId, address indexed player);
    event RewardsDistributed(uint256 indexed roomId, uint256 indexed gameId, address[] recipients, uint256[] amounts);
    event GameEnded(uint256 indexed roomId, uint256 indexed gameId);

    modifier onlyPlayer(uint256 roomId) {
        require(_isPlayerInRoom(roomId, msg.sender), "Not a player in this room");
        _;
    }

    modifier onlyNotPlayer(uint256 roomId) {
        require(!_isPlayerInRoom(roomId, msg.sender), "Already a player in this room");
        _;
    }

    modifier roomExists(uint256 roomId) {
        require(roomId < nextRoomId, "Room does not exist");
        _;
    }

    constructor(ColorNftPouchEth _colorNftPouch)
    Ownable(msg.sender) {
        colorNftPouch = _colorNftPouch;
        nextRoomId = 0;
        feeBalance = 0;
        maxPlayers = 10;
    }

    function _isPlayerInRoom(uint256 roomId, address player)
    internal view returns (bool) {
        address[] storage players = rooms[roomId].players;
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == player) {
                return true;
            }
        }
        return false;
    }

    function getNonce(address user)
    external view returns (uint256) {
        return nonces[user];
    }
    
    function getPlayers(uint256 roomId)
    external view roomExists(roomId) returns (address[] memory) {
        return rooms[roomId].players;
    }

    function setMaxPlayers(uint8 _maxPlayers) external onlyOwner {
        maxPlayers = _maxPlayers;
    }

    function createRoom(uint256 entryPrice, uint256 maxPlayerCount)
    external returns (uint256 roomId) {
        require(maxPlayerCount > 1, "At least 2 players required");
        require(maxPlayerCount < maxPlayers, "Max players allowed exceeded");
        roomId = nextRoomId++;
        Room storage room = rooms[roomId];
        room.entryPrice = entryPrice;
        room.maxPlayerCount = maxPlayerCount;
        room.creationTime = block.timestamp;
        // A game can be replayed in some rooms
        room.gameId = 0;
        room.owner = msg.sender;
        emit RoomCreated(roomId, entryPrice, maxPlayerCount);
    }

    function joinRoom(uint256 roomId, bytes calldata signature)
    external payable roomExists(roomId) nonReentrant onlyNotPlayer(roomId) {
        Room storage room = rooms[roomId];
        require(room.gameStartTime == 0 , "Game already started");
        require(room.players.length < room.maxPlayerCount, "Room is full");
        require(msg.value == room.entryPrice, "Insufficient entry price");
        // Verify signature
        bytes memory message = abi.encodePacked("JoinRoom", msg.sender, roomId, nonces[msg.sender]);
        require(_verify(message, signature), "Not verified");
        room.players.push(msg.sender);

        nonces[msg.sender]++;
        emit PlayerJoined(roomId, msg.sender);
    }

    function leaveRoom(uint256 roomId) 
    external roomExists(roomId) nonReentrant onlyPlayer(roomId) {
        Room storage room = rooms[roomId];
        require(room.gameStartTime == 0, "Cannot leave after game started");
        
        address[] storage players = room.players;
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) {
                players[i] = players[players.length - 1];
                players.pop();
                break;
            }
        }
        
        (bool success, ) = msg.sender.call{value: room.entryPrice}("");
        require(success, "Refund failed");
        
        emit PlayerLeft(roomId, msg.sender);
    }
    
    function startGame(uint256 roomId, bytes calldata signature)
    external roomExists(roomId) nonReentrant {
        Room storage room = rooms[roomId];
        require(room.gameStartTime == 0, "Game already started");
        require(room.players.length >= 2, "At least 2 players required to start");
        
        bytes memory message = abi.encodePacked("StartGame", msg.sender, roomId, room.gameId, nonces[msg.sender]);

        // Verify signature is from owner (deployer)
        require(_verify(message, signature), "Invalid signature");
        
        room.gameStartTime = block.timestamp;

        nonces[msg.sender]++;
        emit GameStarted(roomId, room.gameId);
    }

    function distributeRewards(
        uint256 roomId,
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256[] calldata ids,
        uint256[] calldata idAmounts
    ) external onlyOwner roomExists(roomId) nonReentrant {
        Room storage room = rooms[roomId];
        require(room.gameStartTime != 0, "Game not active");
        require(recipients.length == amounts.length, "Mismatched arrays");
        require(ids.length == idAmounts.length, "Length of ids and amounts must match");
        // Only allow players or the pouch to receive rewards
        uint256 totalReward = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(
                _isPlayerInRoom(roomId, recipients[i]) || recipients[i] == address(colorNftPouch),
                "Not valid recipient"
            );
            totalReward += amounts[i];
        }
        uint256 totalEntry = room.entryPrice * room.players.length;
        require(totalReward <= totalEntry, "Rewards exceed entry fees");
        // Distribute rewards
        for (uint256 i = 0; i < recipients.length; i++) {
            (bool success, ) = recipients[i].call{value: amounts[i]}("");
            require(success, "Eth not arrived");
        }
        // Accumulate fee as leftover
        if (totalEntry > totalReward) {
            feeBalance += (totalEntry - totalReward);
        }
        
        // Distribute NFT rewards
        colorNftPouch.distributeRewards(ids, idAmounts);
        
        emit RewardsDistributed(roomId, room.gameId, recipients, amounts);
        _endGame(roomId);
    }

    function _endGame(uint256 roomId)
    internal {
        Room storage room = rooms[roomId];
        delete room.players;
        room.gameStartTime = 0;
        room.gameId++;
        emit GameEnded(roomId, room.gameId);
    }

    // Withdraws fees and reclaims ETH from rooms older than 15 days, starting from lastWithdrawnRoomId
    function withdrawFees() external onlyOwner {
        require(feeBalance > 0 || nextRoomId > 0, "No fees or rooms to process");
        uint256 totalReclaimed = 0;
        uint256 cutoff = block.timestamp - 15 days;
        uint256 roomId = lastWithdrawnRoomId;
        for (; roomId < nextRoomId; roomId++) {
            Room storage room = rooms[roomId];
            if (room.creationTime >= cutoff) {
                break;
            }
            if (room.players.length > 0) {
                uint256 roomValue = room.entryPrice * room.players.length;
                if (roomValue > 0) {
                    totalReclaimed += roomValue;
                    delete room.players;
                    room.gameStartTime = 0;
                }
            }
        }
        lastWithdrawnRoomId = roomId - 1;
        uint256 payout = feeBalance + totalReclaimed;
        require(payout > 0, "Nothing to withdraw");
        (bool success, ) = msg.sender.call{value: payout}("");
        require(success, "Withdraw failed");
        feeBalance = 0;
    }

    function _verify(bytes memory message, bytes memory signature)
    internal view returns (bool) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(message);
        address signer = ECDSA.recover(signedHash, signature);
        return signer == owner();
    }

}

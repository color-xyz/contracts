// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ColorNftPouchEth.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MultiGameLobbyEth is Ownable, ReentrancyGuard {
    // Custom Errors
    error InvalidMaxPlayers();
    error InvalidEntryPrice();
    error RoomDoesNotExist();
    error NotPlayerInRoom();
    error AlreadyPlayerInRoom();
    error GameAlreadyStarted();
    error RoomIsFull();
    error IncorrectEntryPrice();
    error InvalidSignature();
    error CannotLeaveAfterGameStarted();
    error TransferFailed();
    error GameNotActive();
    error ArrayLengthMismatch();
    error NotValidRecipient();
    error RewardsExceedEntryFees();
    error NoRoomsToProcess();
    error NothingToReclaim();
    error NoFeesToWithdraw();
    error InsufficientNftFunding();
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
    event OldRoomsWithdrawn(uint256 amount);
    event FeesWithdrawn(uint256 amount);

    modifier onlyPlayer(uint256 roomId) {
        if(!_isPlayerInRoom(roomId, msg.sender)) revert NotPlayerInRoom();
        _;
    }

    modifier onlyNotPlayer(uint256 roomId) {
        if(_isPlayerInRoom(roomId, msg.sender)) revert AlreadyPlayerInRoom();
        _;
    }

    modifier roomExists(uint256 roomId) {
        if(roomId >= nextRoomId) revert RoomDoesNotExist();
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
        if(maxPlayerCount <= 1) revert InvalidMaxPlayers();
        if(maxPlayerCount > maxPlayers) revert InvalidMaxPlayers();
        if(entryPrice > 10 ether) revert InvalidEntryPrice();
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
        if(room.gameStartTime != 0) revert GameAlreadyStarted();
        if(room.players.length >= room.maxPlayerCount) revert RoomIsFull();
        if(msg.value != room.entryPrice) revert IncorrectEntryPrice();
        // Verify signature
        bytes memory message = abi.encodePacked("JoinRoom", msg.sender, roomId, nonces[msg.sender]);
        if(!_verify(message, signature)) revert InvalidSignature();
        room.players.push(msg.sender);

        nonces[msg.sender]++;
        emit PlayerJoined(roomId, msg.sender);
    }

    function leaveRoom(uint256 roomId) 
    external roomExists(roomId) nonReentrant onlyPlayer(roomId) {
        Room storage room = rooms[roomId];
        if(room.gameStartTime != 0) revert CannotLeaveAfterGameStarted();
        
        address[] storage players = room.players;
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) {
                players[i] = players[players.length - 1];
                players.pop();
                break;
            }
        }
        
        (bool success, ) = msg.sender.call{value: room.entryPrice}("");
        if(!success) revert TransferFailed();
        
        emit PlayerLeft(roomId, msg.sender);
    }
    
    function startGame(uint256 roomId, bytes calldata signature)
    external roomExists(roomId) nonReentrant {
        Room storage room = rooms[roomId];
        if(room.gameStartTime != 0) revert GameAlreadyStarted();
        if(room.players.length < 2) revert InvalidMaxPlayers();
        
        bytes memory message = abi.encodePacked("StartGame", msg.sender, roomId, room.gameId, nonces[msg.sender]);

        // Verify signature is from owner (deployer)
        if(!_verify(message, signature)) revert InvalidSignature();
        
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
        if(room.gameStartTime == 0) revert GameNotActive();
        if(recipients.length != amounts.length) revert ArrayLengthMismatch();
        if(ids.length != idAmounts.length) revert ArrayLengthMismatch();
        
        // Only allow players or the pouch to receive rewards
        uint256 totalReward = 0;
        uint256 totalPouchAmount = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            if(!_isPlayerInRoom(roomId, recipients[i]) && recipients[i] != address(colorNftPouch)) {
                revert NotValidRecipient();
            }
            totalReward += amounts[i];
            if (recipients[i] == address(colorNftPouch)) {
                totalPouchAmount += amounts[i];
            }
        }
        uint256 totalEntry = room.entryPrice * room.players.length;
        if(totalReward > totalEntry) revert RewardsExceedEntryFees();
        
        uint256 totalNftRewards = 0;
        for (uint256 i = 0; i < idAmounts.length; i++) {
            totalNftRewards += idAmounts[i];
        }
        if(totalNftRewards > totalPouchAmount) revert InsufficientNftFunding();
        
        // Distribute rewards
        for (uint256 i = 0; i < recipients.length; i++) {
            (bool success, ) = recipients[i].call{value: amounts[i]}("");
            if(!success) revert TransferFailed();
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

    // Reclaims ETH from rooms older than 15 days, starting from lastWithdrawnRoomId
    function _withdrawOldRooms(uint256 limit) internal returns (uint256) {
        if(nextRoomId == 0) revert NoRoomsToProcess();
        uint256 totalReclaimed = 0;
        uint256 cutoff = block.timestamp - 15 days;
        uint256 roomId = lastWithdrawnRoomId;
        uint256 processedCount = 0;

        for (; roomId < nextRoomId; roomId++) {
            if (limit > 0 && processedCount >= limit) {
                break;
            }

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
                    processedCount++;
                }
            }
        }
        lastWithdrawnRoomId = roomId;
        return totalReclaimed;
    }

    function withdrawOldRooms(uint256 limit) external onlyOwner {
        uint256 reclaimed = _withdrawOldRooms(limit);
        if(reclaimed == 0) revert NothingToReclaim();
        (bool success, ) = msg.sender.call{value: reclaimed}("");
        if(!success) revert TransferFailed();
        emit OldRoomsWithdrawn(reclaimed);
    }

    function withdrawFees() external onlyOwner {
        if(feeBalance == 0) revert NoFeesToWithdraw();
        uint256 payout = feeBalance;
        feeBalance = 0;
        (bool success, ) = msg.sender.call{value: payout}("");
        if(!success) revert TransferFailed();
        emit FeesWithdrawn(payout);
    }

    function _verify(bytes memory message, bytes memory signature)
    internal view returns (bool) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(message);
        address signer = ECDSA.recover(signedHash, signature);
        return signer == owner();
    }

}

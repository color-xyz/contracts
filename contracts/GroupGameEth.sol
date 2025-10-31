// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ColorNftPouchEth.sol";

import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GroupGameEth is Ownable, ReentrancyGuard {
    ColorNftPouchEth public colorNftPouch;
    uint256 public maxPlayerCount;
    uint256 public entryPrice;
    uint256 public nextId;
    uint256 public feeBalance;

    struct Game {
        uint256 creationTime;
        address[] players;
        address[] recipients;
        uint256[] amounts;
        uint256[] ids;
        uint256[] idAmounts;
        address[] cashBackedPlayers;
    }

    mapping(uint256 => Game) games;
    mapping(address => uint256[]) public playerPlayedGameIds;


    event GameStart(uint256 indexed _id);
    event PlayerJoined(uint256 indexed _id, address indexed _player);
    event PlayerLeft(uint256 indexed _id, address indexed _player);
    event RewardsSent(uint256 indexed _id, address[] _recipients, uint256[] _amounts, uint256[] _ids, uint256[] _idAmounts);
    event CashBack(uint256 indexed _id, address indexed _player);

    modifier senderInGame {
        bool result = false;
        for(uint16 i = 0; i < games[nextId].players.length; i++) {
            if(msg.sender == games[nextId].players[i]) result = true;
        }
        require(result, "Game already started");
        _;
    }

    modifier senderNotInGame {
        for(uint16 i = 0; i < games[nextId].players.length; i++) {
            require(msg.sender != games[nextId].players[i], "Already in a game");
        }
        _;
    }

    constructor(ColorNftPouchEth _colorNftPouch, uint256 _maxPlayerCount, uint256 _entryPrice) Ownable(msg.sender) {
        colorNftPouch = _colorNftPouch;
        maxPlayerCount = _maxPlayerCount;
        entryPrice = _entryPrice;
        feeBalance = 0;
        nextId = 0;
    }

    function getPlayersInGame(uint256 _id)
    external view returns(address[] memory) {
        require(_id <= nextId, "Invalid id");
        return games[_id].players;
    }
    
    function getGame(uint256 _id)
    external view returns(Game memory) {
        require(_id <= nextId, "Invalid id");
        return games[_id];
    }

    function getPlayerPlayedGameIds(address _player)
    external view returns (uint256[] memory) {
        require(_player != address(0), "Invalid address");
        return playerPlayedGameIds[_player];
    }

    function join(bytes calldata _signature)
    external senderNotInGame nonReentrant payable returns(uint256 _id) {
        require(msg.value >= entryPrice, "Not enough eth sent");
        bytes memory message = abi.encodePacked(
            bytes("Join"),
            address(msg.sender),
            bytes32(maxPlayerCount),
            bytes32(entryPrice),
            bytes32(playerPlayedGameIds[msg.sender].length)
        );
        require(_verify(message, _signature), "Not verified");

        playerPlayedGameIds[msg.sender].push(nextId);
        games[nextId].players.push(msg.sender);
        emit PlayerJoined(nextId, msg.sender);
        if(games[nextId].players.length >= maxPlayerCount) {
            games[nextId].creationTime = block.timestamp;
            emit GameStart(nextId);
            return nextId++;
        }
        return nextId;
    }

    function leave()
    senderInGame nonReentrant external {
        (bool success, ) = msg.sender.call{value: entryPrice}("");
        require(success, "Eth not arrived");

        address[] storage players = games[nextId].players;
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) {
                players[i] = players[players.length - 1];
                players.pop();
                break;
            }
        }
        playerPlayedGameIds[msg.sender].pop();
        emit PlayerLeft(nextId, msg.sender);
    }
    
    function sendRewards(
        uint256 _id,
        address[] calldata _recipients,
        uint256[] calldata _amounts,
        uint256[] calldata _ids,
        uint256[] calldata _idAmounts
    ) external onlyOwner {
        require(_id < nextId, "Invalid id");
        require(_recipients.length == _amounts.length, "Length of recipients and amounts must match");
        require(_ids.length == _idAmounts.length, "Length of ids and amounts must match");
        require(games[_id].creationTime != 0, "Game has not started yet");
        require(block.timestamp - games[_id].creationTime < 15 * 60, "Rewards can only be sent in the first 15 minutes from the game start");
        require(games[_id].recipients.length == 0, "Rewards are already distributed");

        for (uint256 i = 0; i < _recipients.length; i++) {
            if(_recipients[i] == address(this)) {
                feeBalance += _amounts[i];
            } else {
                (bool success, ) = _recipients[i].call{value: _amounts[i]}("");
                require(success, "Eth not arrived");
            }
        }

        colorNftPouch.distributeRewards(_ids, _idAmounts);
        // Maybe create a copy and assigning after results in less gas
        games[_id].recipients = _recipients;
        games[_id].amounts = _amounts;
        games[_id].ids = _ids;
        games[_id].idAmounts = _idAmounts;
        emit RewardsSent(_id, _recipients, _amounts, _ids, _idAmounts);
    }

    function cashBack(
        uint256 _id
    ) external nonReentrant {
        require(_id < nextId, "Invalid id");
        bool result = false;
        Game memory game = games[_id];
        for(uint16 i = 0; i < game.players.length; i++) {
            if(msg.sender == game.players[i]) result = true;
        }
        require(result, "Player is not in the game");
        require(block.timestamp - game.creationTime > 15 * 60, "Cashback only available if game has not finished in 15 minutes");
        require(games[_id].recipients.length == 0, "Game is finished, rewards are already distributed");
        bool playerAlreadyCashBacked = false;
        for (uint16 i = 0; i < game.cashBackedPlayers.length; i++) {
            if (msg.sender == game.cashBackedPlayers[i]) playerAlreadyCashBacked = true;
        }
        require(!playerAlreadyCashBacked, "Player already cashBacked");

        (bool success, ) = msg.sender.call{value: entryPrice}("");
        require(success, "Eth not arrived");

        games[_id].cashBackedPlayers.push(msg.sender);

        emit CashBack(_id, msg.sender);
    }

    function withdraw()
    external onlyOwner payable {
        require(feeBalance > 0, "No fee to withdraw");

        (bool success, ) = msg.sender.call{value: feeBalance}("");
        require(success, "Withdraw was not successful");

        feeBalance = 0;
    }

    function _verify(bytes memory _message, bytes memory _signature)
    internal view returns(bool) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(_message);
        address signer = ECDSA.recover(signedHash, _signature);

        return signer == address(owner());
    }
}
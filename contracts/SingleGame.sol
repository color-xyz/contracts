// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SingleGame {
    uint256 public nextId;

    mapping(uint256 => address) games;

    event GameStart(uint256 indexed _id, address indexed _player);

    function game(uint256 _id)
    external view returns(address) {
        require(_id < nextId, "Invalid gameId");
        return games[_id];
    }

    function join()
    external returns(uint256) {
        games[nextId] = msg.sender;

        emit GameStart(nextId, msg.sender);
        nextId++;

        return nextId;
    }
}
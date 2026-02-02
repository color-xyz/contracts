// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @dev Interface for ColorNftPouch contract
 */
interface IColorNftPouch {
    function distributeRewards(uint256[] calldata _ids, uint256[] calldata _amounts) external;
}

/**
 * @title TournamentManager
 * @notice Manages tournament registrations, prize pools, and reward distributions
 */
contract TournamentManager is Ownable, ReentrancyGuard {
    struct TournamentData {
        uint256 tournamentId;
        address creator;
        uint256 entryFee;
        uint256 maxPlayers;
        uint256 prizePool;
        uint256 incentivePool;
        uint256 creationTime;
        uint256 registrationDeadline;
        uint256 startTime;
        uint8 platformFeePercent;
        uint8 nftRewardPercent;
        bool isFinalized;
        bool isActive;
    }

    mapping(uint256 => TournamentData) public tournaments;
    mapping(uint256 => mapping(address => bool)) public hasRegistered;
    mapping(uint256 => address[]) public tournamentPlayers;
    mapping(address => uint256) public nonces;
    
    uint256 public nextTournamentId = 1;
    uint256 public platformFeeBalance;
    uint256 public lastWithdrawnTournamentId;
    address public colorNftPouch;

    event TournamentCreated(
        uint256 indexed tournamentId, 
        address indexed creator, 
        uint256 entryFee, 
        uint256 maxPlayers,
        uint256 registrationDeadline,
        uint256 startTime
    );
    event PlayerRegistered(uint256 indexed tournamentId, address indexed player, uint256 amountPaid);
    event PlayerUnregistered(uint256 indexed tournamentId, address indexed player, uint256 amountRefunded);
    event PlayerRefunded(uint256 indexed tournamentId, address indexed player, uint256 amountRefunded);
    event IncentiveAdded(uint256 indexed tournamentId, address indexed sponsor, uint256 amount);
    event TournamentFinalized(uint256 indexed tournamentId, uint256 totalDistributed, uint256 platformFee);
    event TournamentCancelled(uint256 indexed tournamentId, uint256 totalRefunded);
    event PlatformFeesWithdrawn(uint256 amount);

    constructor(address _colorNftPouch) Ownable(msg.sender) {
        require(_colorNftPouch != address(0), "Invalid pouch address");
        colorNftPouch = _colorNftPouch;
    }

    /**
     * @notice Update ColorNftPouch contract address
     * @param _colorNftPouch New ColorNftPouch contract address
     */
    function setColorNftPouch(address _colorNftPouch) external onlyOwner {
        require(_colorNftPouch != address(0), "Invalid pouch address");
        colorNftPouch = _colorNftPouch;
    }

    /**
     * @notice Create a new tournament
     * @param entryFee Entry fee in wei (0 for free tournaments)
     * @param maxPlayers Maximum number of players allowed
     * @param registrationDeadline Timestamp when registration closes
     * @param startTime Timestamp when tournament starts (0 for flexible start)
     * @param platformFeePercent Platform fee percentage (e.g., 5 for 5%)
     * @param nftRewardPercent NFT reward percentage (e.g., 5 for 5%)
     * @return tournamentId The ID of the created tournament
     */
    function createTournament(
        uint256 entryFee, 
        uint256 maxPlayers,
        uint256 registrationDeadline,
        uint256 startTime,
        uint8 platformFeePercent,
        uint8 nftRewardPercent
    ) external onlyOwner returns (uint256) {
        require(registrationDeadline < startTime || startTime == 0, "Registration must end before start");
        
        uint256 tournamentId = nextTournamentId++;
        
        tournaments[tournamentId] = TournamentData({
            tournamentId: tournamentId,
            creator: msg.sender,
            entryFee: entryFee,
            maxPlayers: maxPlayers,
            prizePool: 0,
            incentivePool: 0,
            creationTime: block.timestamp,
            registrationDeadline: registrationDeadline,
            startTime: startTime,
            platformFeePercent: platformFeePercent,
            nftRewardPercent: nftRewardPercent,
            isFinalized: false,
            isActive: true
        });

        emit TournamentCreated(tournamentId, msg.sender, entryFee, maxPlayers, registrationDeadline, startTime);
        return tournamentId;
    }

    /**
     * @notice Register for a tournament
     * @param tournamentId ID of the tournament to join
     */
    function registerPlayer(uint256 tournamentId, bytes calldata signature) external payable nonReentrant {
        TournamentData storage tournament = tournaments[tournamentId];
        
        require(tournament.isActive, "Tournament not active");
        require(!tournament.isFinalized, "Tournament already finalized");
        require(!hasRegistered[tournamentId][msg.sender], "Already registered");
        require(tournamentPlayers[tournamentId].length < tournament.maxPlayers, "Tournament is full");
        require(block.timestamp < tournament.registrationDeadline, "Registration deadline passed");
        
        // Verify signature
        bytes memory message = abi.encodePacked("RegisterTournament", msg.sender, tournamentId, nonces[msg.sender]);
        require(_verify(message, signature), "Invalid signature");
        
        require(msg.value == tournament.entryFee, "Incorrect entry fee");
        if (msg.value > 0) {
            tournament.prizePool += msg.value;
        }
        
        hasRegistered[tournamentId][msg.sender] = true;
        tournamentPlayers[tournamentId].push(msg.sender);
        
        nonces[msg.sender]++;
        emit PlayerRegistered(tournamentId, msg.sender, msg.value);
    }

    /**
     * @notice Unregister from a tournament before it starts
     * @param tournamentId ID of the tournament to leave
     */
    function unregisterPlayer(uint256 tournamentId, bytes calldata signature) external nonReentrant {
        TournamentData storage tournament = tournaments[tournamentId];
        
        require(tournament.isActive, "Tournament not active");
        require(!tournament.isFinalized, "Tournament already started");
        require(hasRegistered[tournamentId][msg.sender], "Not registered");
        require(block.timestamp < tournament.registrationDeadline, "Registration deadline passed");
        
        // Verify signature
        bytes memory message = abi.encodePacked("UnregisterTournament", msg.sender, tournamentId, nonces[msg.sender]);
        require(_verify(message, signature), "Invalid signature");
        
        hasRegistered[tournamentId][msg.sender] = false;
        
        // Remove from players array (swap and pop)
        address[] storage players = tournamentPlayers[tournamentId];
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) {
                players[i] = players[players.length - 1];
                players.pop();
                break;
            }
        }
        
        // Refund entry fee
        if (tournament.entryFee > 0) {
            uint256 refundAmount = tournament.entryFee;
            tournament.prizePool -= refundAmount;
            
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            require(success, "Refund failed");
            
            emit PlayerUnregistered(tournamentId, msg.sender, refundAmount);
        } else {
            emit PlayerUnregistered(tournamentId, msg.sender, 0);
        }
        
        nonces[msg.sender]++;
    }

    /**
     * @notice Claim refund if tournament hasn't been finalized 8 hours after start time
     * @param tournamentId ID of the tournament
     */
    function claimAbandonedTournamentRefund(uint256 tournamentId) external nonReentrant {
        TournamentData storage tournament = tournaments[tournamentId];
        
        require(tournament.isActive, "Tournament not active");
        require(!tournament.isFinalized, "Tournament already finalized");
        require(hasRegistered[tournamentId][msg.sender], "Not registered");
        require(tournament.startTime != 0, "No start time set");
        require(block.timestamp >= tournament.startTime + 8 hours, "8 hours not passed since start time");
        
        hasRegistered[tournamentId][msg.sender] = false;
        
        // Remove from players array (swap and pop)
        address[] storage players = tournamentPlayers[tournamentId];
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) {
                players[i] = players[players.length - 1];
                players.pop();
                break;
            }
        }
        
        // Refund entry fee
        if (tournament.entryFee > 0) {
            uint256 refundAmount = tournament.entryFee;
            tournament.prizePool -= refundAmount;
            
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            require(success, "Refund failed");
            
            emit PlayerRefunded(tournamentId, msg.sender, refundAmount);
        } else {
            emit PlayerRefunded(tournamentId, msg.sender, 0);
        }
    }

    /**
     * @notice Add incentive to tournament prize pool
     * @param tournamentId ID of the tournament
     */
    function addIncentive(uint256 tournamentId) external payable {
        TournamentData storage tournament = tournaments[tournamentId];
        
        require(tournament.isActive, "Tournament not active");
        require(!tournament.isFinalized, "Tournament already finalized");
        require(msg.value > 0, "Must send incentive");
        
        tournament.incentivePool += msg.value;
        
        emit IncentiveAdded(tournamentId, msg.sender, msg.value);
    }

    /**
     * @notice Distribute final rewards to winners (admin only)
     * @param tournamentId ID of the tournament
     * @param winners Array of winner addresses in ranking order (parallel to playerAmounts)
     * @param playerAmounts Reward amounts for each winner (parallel to winners)
     * @param nftIds Array of NFT IDs to reward (parallel to nftAmounts)
     * @param nftAmounts Reward amounts for each NFT ID (parallel to nftIds)
     */
    function distributeFinalRewards(
        uint256 tournamentId,
        address[] calldata winners,
        uint256[] calldata playerAmounts,
        uint256[] calldata nftIds,
        uint256[] calldata nftAmounts
    ) external onlyOwner nonReentrant {
        TournamentData storage tournament = tournaments[tournamentId];
        
        require(tournament.isActive, "Tournament not active");
        require(!tournament.isFinalized, "Already finalized");
        require(winners.length == playerAmounts.length, "Winners/amounts mismatch");
        require(nftIds.length == nftAmounts.length, "NFT IDs/amounts mismatch");
        
        // Calculate platform fee (% of entry fees only, not incentives)
        uint256 platformFee = (tournament.prizePool * tournament.platformFeePercent) / 100;
        
        uint256 totalDistributed = _distributeRewards(
            tournamentId,
            winners,
            playerAmounts,
            nftIds,
            nftAmounts,
            platformFee
        );
        
        tournament.isFinalized = true;
        emit TournamentFinalized(tournamentId, totalDistributed, platformFee);
    }

    /**
     * @dev Internal function to distribute rewards
     * @param tournamentId ID of the tournament
     * @param winners Array of winner addresses
     * @param playerAmounts Array of amounts for each winner
     * @param nftIds Array of NFT IDs to reward (parallel to nftAmounts)
     * @param nftAmounts Array of amounts for each NFT ID (parallel to nftIds)
     * @param platformFee Platform fee to accumulate
     * @return totalDistributed Total amount distributed to players and NFTs
     */
    function _distributeRewards(
        uint256 tournamentId,
        address[] calldata winners,
        uint256[] calldata playerAmounts,
        uint256[] calldata nftIds,
        uint256[] calldata nftAmounts,
        uint256 platformFee
    ) internal returns (uint256 totalDistributed) {
        // Distribute to players and calculate total
        for (uint256 i = 0; i < winners.length; i++) {
            if (playerAmounts[i] > 0) {
                totalDistributed += playerAmounts[i];
                (bool success, ) = winners[i].call{value: playerAmounts[i]}("");
                require(success, "Player transfer failed");
            }
        }
        
        // Distribute NFT rewards through the pouch
        if (nftIds.length > 0 && colorNftPouch != address(0)) {
            // Calculate total NFT rewards
            uint256 totalNftRewards = 0;
            for (uint256 i = 0; i < nftAmounts.length; i++) {
                totalNftRewards += nftAmounts[i];
            }
            
            // Send total to pouch, then call distributeRewards
            if (totalNftRewards > 0) {
                totalDistributed += totalNftRewards;
                (bool nftSuccess, ) = colorNftPouch.call{value: totalNftRewards}("");
                require(nftSuccess, "NFT pouch transfer failed");
                
                // Call pouch to distribute to NFT owners using parallel arrays
                IColorNftPouch(colorNftPouch).distributeRewards(nftIds, nftAmounts);
            }
        }
        
        // Accumulate platform fee
        platformFeeBalance += platformFee;
        
        // Validate distribution is within boundaries
        // Prize pool and incentive pool are tracked on-chain through register/unregister
        TournamentData storage tournament = tournaments[tournamentId];
        uint256 totalAvailable = tournament.prizePool + tournament.incentivePool;
        require(totalDistributed + platformFee <= totalAvailable, "Distribution exceeds available funds");
    }

    /**
     * @notice Cancel tournament and refund all players
     * @param tournamentId ID of the tournament to cancel
     */
    function cancelTournament(uint256 tournamentId) external onlyOwner nonReentrant {
        TournamentData storage tournament = tournaments[tournamentId];
        require(tournament.isActive, "Tournament not active");
        require(!tournament.isFinalized, "Already finalized");
        
        tournament.isActive = false;
        
        uint256 totalRefunded = 0;
        
        // Refund all registered players
        if (tournament.entryFee > 0) {
            address[] storage players = tournamentPlayers[tournamentId];
            for (uint256 i = 0; i < players.length; i++) {
                if (hasRegistered[tournamentId][players[i]]) {
                    (bool success, ) = players[i].call{value: tournament.entryFee}("");
                    require(success, "Refund failed");
                    totalRefunded += tournament.entryFee;
                }
            }
        }
        
        // Refund third party incentives to creator
        if (tournament.incentivePool > 0) {
            (bool success, ) = tournament.creator.call{value: tournament.incentivePool}("");
            require(success, "Incentive refund failed");
            totalRefunded += tournament.incentivePool;
        }
        
        emit TournamentCancelled(tournamentId, totalRefunded);
    }

    /**
     * @notice Withdraw platform fees and reclaim funds from old tournaments
     */
    function withdrawPlatformFees() external onlyOwner {
        require(platformFeeBalance > 0 || nextTournamentId > 1, "No fees or tournaments to process");
        
        uint256 totalReclaimed = 0;
        uint256 cutoff = block.timestamp - 15 days;
        uint256 tournamentId = lastWithdrawnTournamentId + 1;
        
        // Reclaim funds from old unfinalized tournaments
        for (; tournamentId < nextTournamentId; tournamentId++) {
            TournamentData storage tournament = tournaments[tournamentId];
            
            // Stop if we reach recent tournaments
            if (tournament.creationTime >= cutoff) {
                break;
            }
            
            // Skip if already finalized or cancelled
            if (!tournament.isActive || tournament.isFinalized) {
                continue;
            }
            
            // Reclaim both prize pool and incentive pool from old unfinalized tournament
            uint256 reclaimAmount = tournament.prizePool + tournament.incentivePool;
            if (reclaimAmount > 0) {
                totalReclaimed += reclaimAmount;
                tournament.prizePool = 0;
                tournament.incentivePool = 0;
                tournament.isActive = false;
            }
        }
        
        lastWithdrawnTournamentId = tournamentId - 1;
        
        uint256 payout = platformFeeBalance + totalReclaimed;
        require(payout > 0, "Nothing to withdraw");
        
        platformFeeBalance = 0;
        
        (bool success, ) = owner().call{value: payout}("");
        require(success, "Withdraw failed");
        
        emit PlatformFeesWithdrawn(payout);
    }

    /**
     * @notice Get tournament details
     * @param tournamentId ID of the tournament
     */
    function getTournament(uint256 tournamentId) external view returns (TournamentData memory) {
        return tournaments[tournamentId];
    }

    /**
     * @notice Get registered players for a tournament
     * @param tournamentId ID of the tournament
     */
    function getPlayers(uint256 tournamentId) external view returns (address[] memory) {
        return tournamentPlayers[tournamentId];
    }

    /**
     * @notice Get number of registered players
     * @param tournamentId ID of the tournament
     */
    function getPlayerCount(uint256 tournamentId) external view returns (uint256) {
        return tournamentPlayers[tournamentId].length;
    }

    /**
     * @notice Check if a player is registered
     * @param tournamentId ID of the tournament
     * @param player Address to check
     */
    function isPlayerRegistered(uint256 tournamentId, address player) external view returns (bool) {
        return hasRegistered[tournamentId][player];
    }

    /**
     * @notice Get nonce for a user
     * @param user Address to check
     */
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /**
     * @notice Verify signature from owner
     * @param message The message that was signed
     * @param signature The signature to verify
     */
    function _verify(bytes memory message, bytes memory signature) internal view returns (bool) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(message);
        address signer = ECDSA.recover(signedHash, signature);
        return signer == owner();
    }
}

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol"
import "@openzeppelin/contracts/access/Ownable.sol"
import "@openzeppelin/contracts/utils/Pausable.sol"
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"

contract Dice is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
	using SafeERC20 for IERC20;

    uint256 public currentEpoch;
    uint256 public intervalBlocks;
    uint256 public bufferBlocks;
    address public adminAddress;
    address public operatorAddress;
    uint256 public treasuryAmount;

    uint256 public constant TOTAL_RATE = 100; // 100%
	uint256 public gapRate = 5;
    uint256 public treasuryRate = 10; // 10% in gap
	uint256 public bonusRate = 10; // 10% in gap
	uint256 public edgeRate = 80; // 80% in gap
	
    uint256 public minBetAmount;

    bool public genesisStartOnce = false;

	IERC20 public token;

    struct Round {
        uint256 startBlock;
        uint256 lockBlock;
		uint256 secretSentBlock;
		bytes32 bankHash;
        uint256 bankSecret;
        uint256 totalAmount;
		uint256[6] betAmounts;
        uint256 rewardAmount;
		uint256 betUsers;
		uint32 finalNumber;
    }

    struct BetInfo {
        uint256 amount;
		bool[6] numbers;
        bool claimed; // default false
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(address => uint256[]) public userRounds;

    event StartRound(uint256 indexed epoch, uint256 blockNumber, bytes32 bankHash);
    event LockRound(uint256 indexed epoch, uint256 blockNumber);
    event SendSecretRound(uint256 indexed epoch, uint256 blockNumber, uint256 bankSecret, uint32 finalNumber);
    event BetNumber(address indexed sender, uint256 indexed currentEpoch, bool[6] numbers, uint256 amount);
    event Claim(address indexed sender, uint256 indexed currentEpoch, uint256 amount);
    event ClaimTreasury(uint256 amount);
    event GapRateUpdated(uint256 indexed epoch, uint256 gapRate);
    event RatesUpdated(uint256 indexed epoch, uint256 treasuryRate, uint256 bonusRate, uint256 edgeRate);
    event MinBetAmountUpdated(uint256 indexed epoch, uint256 minBetAmount);
    event RewardsCalculated(
        uint256 indexed epoch,
        uint256 rewardBaseCalAmount,
        uint256 rewardAmount,
        uint256 treasuryAmount
    );
    event Pause(uint256 epoch);
    event Unpause(uint256 epoch);

    constructor(
		address _tokenAddress,
        address _adminAddress,
        address _operatorAddress,
        uint256 _intervalBlocks,
        uint256 _bufferBlocks,
        uint256 _minBetAmount,
    ) public {
		token = IERC20(_tokenAddress);
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        intervalBlocks = _intervalBlocks;
        bufferBlocks = _bufferBlocks;
        minBetAmount = _minBetAmount;
    }

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "admin: wut?");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "operator: wut?");
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, "admin | operator: wut?");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    /**
     * @dev set admin address
     * callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;
    }

    /**
     * @dev set operator address
     * callable by admin
     */
    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), "Cannot be zero address");
        operatorAddress = _operatorAddress;
    }

    /**
     * @dev set interval blocks
     * callable by admin
     */
    function setIntervalBlocks(uint256 _intervalBlocks) external onlyAdmin {
        intervalBlocks = _intervalBlocks;
    }

    /**
     * @dev set buffer blocks
     * callable by admin
     */
    function setBufferBlocks(uint256 _bufferBlocks) external onlyAdmin {
        require(_bufferBlocks <= intervalBlocks, "Cannot be more than intervalBlocks");
        bufferBlocks = _bufferBlocks;
    }


    /**
     * @dev set gap rate
     * callable by admin
     */
    function setGapRate(uint256 _gapRate) external onlyAdmin {
        require(_gapRate <= 10, "gapRate cannot be more than 10%");
        gapRate = _gapRate;

        emit GapRateUpdated(currentEpoch, gapRate);
    }

    /**
     * @dev set treasury rate
     * callable by admin
     */
    function setRates(uint256 _treasuryRate, uint256 _bonusRate, uint256 _edgeRate) external onlyAdmin {
        require(_treasuryRate.add(_bonusRate).add(_edgeRate) == TOTAL_RATE, "rates must sum to 100%");
		treasuryRate = _treasuryRate;
		bonusRate = _bonusRate;
		edgeRate = _edgeRate;

        emit RatesUpdated(currentEpoch, treasuryRate, bonusRate, edgeRate);
    }

    /**
     * @dev set minBetAmount
     * callable by admin
     */
    function setMinBetAmount(uint256 _minBetAmount) external onlyAdmin {
        minBetAmount = _minBetAmount;

        emit MinBetAmountUpdated(currentEpoch, minBetAmount);
    }

    /**
     * @dev Start genesis round
     */
    function genesisStartRound(uint256 epoch, bytes32 bankHash) external onlyOperator whenNotPaused {
        require(!genesisStartOnce, "Can only run genesisStartRound once");
        require(epoch == currentEpoch + 1, "epoch should equals currentEposh + 1");
        
        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch, bankHash);
        genesisStartOnce = true;
    }

    /**
     * @dev Start the next round n, lock for round n-1
     */
    function executeRound(uint256 epoch, bytes32 bankHash) external onlyOperator whenNotPaused nonReentrant {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");
        require(epoch == currentEpoch, "epoch should equals currentEposh");

        // CurrentEpoch refers to previous round (n-1)
        _safeLockRound(currentEpoch);

        // Increment currentEpoch to current round (n)
        currentEpoch = currentEpoch + 1;
        _safeStartRound(currentEpoch, bankHash);
    }

	
    /**
     * @dev send bankSecret
     */
	function sendSecret(uint256 epoch, uint256 bankSecret) external onlyOperator whenNotPaused nonReentrant {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");
        require(rounds[epoch].lockBlock != 0, "Can only end round after round has locked");
        require(block.number >= rounds[epoch].lockBlock, "Can only send secret after lockBlock");
        require(block.number <= rounds[epoch].lockBlock.add(bufferBlocks), "Can only send secret within bufferBlocks");
		require(rounds[epoch].bankSecret == 0, "Already revealed");
        require(keccak256(abi.encodePacked(bankSecret)) == rounds[epoch].bankHash, "Bank reveal not matching commitment");

		_safeSendSecret(epoch, bankSecret);
		_calculateRewards(epoch);
	}

    function _safeSendSecret(uint256 epoch, uint256 bankSecret) internal {
        Round storage round = rounds[epoch];
		round.secretSentBlock = block.number;
		round.bankSecret = bankSecret;
		uint256 random = round.bankSecret ^ round.betUsers;
		round.finalNumber = uint32(random % 6);

        emit SendSecretRound(epoch, block.number, bankSecret, round.finalNumber);
    }	

    /**
     * @dev bet number
     */
    function betNumber(bool[6] calldata numbers, uint256 amount) external whenNotPaused notContract nonReentrant {
        require(_bettable(currentEpoch), "Round not bettable");
        require(msg.value >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(ledger[currentEpoch][msg.sender].amount == 0, "Can only bet once per round");

		token.safeTransferFrom(address(msg.sender), address(this), amount);

        // Update round data
        Round storage round = rounds[currentEpoch];
        round.totalAmount = round.totalAmount.add(amount);
        round.bearAmount = round.bearAmount.add(amount);
        round.betUsers = round.betUsers.add(1);

        // Update user data
        BetInfo storage betInfo = ledger[currentEpoch][msg.sender];
		betInfo.numbers = betInfo.numbers;
        betInfo.amount = amount;
        userRounds[msg.sender].push(currentEpoch);

        emit BetNumber(msg.sender, currentEpoch, numbers, amount);
    }


    /**
     * @dev Claim reward
     */
    function claim(uint256 epoch) external notContract nonReentrant {
        require(rounds[epoch].startBlock != 0, "Round has not started");
        require(block.number > rounds[epoch].lockBlock, "Round has not locked");
        require(!ledger[epoch][msg.sender].claimed, "Rewards claimed");

        uint256 reward;
        // Round valid, claim rewards
        if (rounds[epoch].secretSentBlock != 0) {
            require(claimable(epoch, msg.sender), "Not eligible for claim");
            Round memory round = rounds[epoch];
            reward = ledger[epoch][msg.sender].amount.mul(round.rewardAmount).div(round.rewardBaseCalAmount);
        }
        // Round invalid, refund bet amount
        else {
            require(refundable(epoch, msg.sender), "Not eligible for refund");
            reward = ledger[epoch][msg.sender].amount;
        }

        BetInfo storage betInfo = ledger[epoch][msg.sender];
        betInfo.claimed = true;
		token.safeTransfer(msg.sender, reward);

        emit Claim(msg.sender, epoch, reward);
    }

    /**
     * @dev Claim all rewards in treasury
     * callable by admin
     */
    function claimTreasury() external onlyAdmin nonReentrant {
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
		
		token.safeTransfer(adminAddress, currentTreasuryAmount)

        emit ClaimTreasury(currentTreasuryAmount);
    }

    /**
     * @dev Return round epochs that a user has participated
     */
    function getUserRounds(
        address user,
        uint256 cursor,
        uint256 size
    ) external view returns (uint256[] memory, uint256) {
        uint256 length = size;
        if (length > userRounds[user].length - cursor) {
            length = userRounds[user].length - cursor;
        }

        uint256[] memory values = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            values[i] = userRounds[user][cursor + i];
        }

        return (values, cursor + length);
    }

    /**
     * @dev called by the admin to pause, triggers stopped state
     */
    function pause() public onlyAdminOrOperator whenNotPaused {
        _pause();

        emit Pause(currentEpoch);
    }

    /**
     * @dev called by the admin to unpause, returns to normal state
     * Reset genesis state. Once paused, the rounds would need to be kickstarted by genesis
     */
    function unpause() public onlyAdmin whenPaused {
        genesisStartOnce = false;
        genesisLockOnce = false;
        _unpause();

        emit Unpause(currentEpoch);
    }

    /**
     * @dev Get the claimable stats of specific epoch and user account
     */
    function claimable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];
        return
            (round.secretSentBlock != 0) &&
            ((round.closePrice > round.lockPrice && betInfo.position == Position.Bull) ||
                (round.closePrice < round.lockPrice && betInfo.position == Position.Bear));
    }

    /**
     * @dev Get the refundable stats of specific epoch and user account
     */
    function refundable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];
        return (round.secretSentBlock == 0) && block.number > round.lockBlock.add(bufferBlocks) && betInfo.amount != 0;
    }

    /**
     * @dev Start round
     * Previous round n-2 must end
     */
    function _safeStartRound(uint256 epoch, bytes32 bankHash) internal {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");
        require(block.number >= rounds[epoch - 1].lockBlock, "Can only start new round after round n-1 lockBlock");
        _startRound(epoch, bankHash);
    }

    function _startRound(uint256 epoch, bytes32 bankHash) internal {
        Round storage round = rounds[epoch];
        round.startBlock = block.number;
        round.lockBlock = block.number.add(intervalBlocks);
		round.bankHash = bankHash
        round.totalAmount = 0;

        emit StartRound(epoch, block.number, bankHash);
    }

    /**
     * @dev Lock round
     */
    function _safeLockRound(uint256 epoch) internal {
        require(rounds[epoch].startBlock != 0, "Can only lock round after round has started");
        require(block.number >= rounds[epoch].lockBlock, "Can only lock round after lockBlock");
        require(block.number <= rounds[epoch].lockBlock.add(bufferBlocks), "Can only lock round within bufferBlocks");
        _lockRound(epoch);
    }

    function _lockRound(uint256 epoch) internal {
        emit LockRound(epoch, block.number);
    }


    /**
     * @dev Calculate rewards for round
     */
    function _calculateRewards(uint256 epoch) internal {
        require(rewardRate.add(treasuryRate) == TOTAL_RATE, "rewardRate and treasuryRate must add up to TOTAL_RATE");
        require(rounds[epoch].rewardBaseCalAmount == 0 && rounds[epoch].rewardAmount == 0, "Rewards calculated");
        Round storage round = rounds[epoch];
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
        uint256 treasuryAmt;
        // Bull wins
        if (round.closePrice > round.lockPrice) {
            rewardBaseCalAmount = round.bullAmount;
            rewardAmount = round.totalAmount.mul(rewardRate).div(TOTAL_RATE);
            treasuryAmt = round.totalAmount.mul(treasuryRate).div(TOTAL_RATE);
        }
        // Bear wins
        else if (round.closePrice < round.lockPrice) {
            rewardBaseCalAmount = round.bearAmount;
            rewardAmount = round.totalAmount.mul(rewardRate).div(TOTAL_RATE);
            treasuryAmt = round.totalAmount.mul(treasuryRate).div(TOTAL_RATE);
        }
        // House wins
        else {
            rewardBaseCalAmount = 0;
            rewardAmount = 0;
            treasuryAmt = round.totalAmount;
        }
        round.rewardBaseCalAmount = rewardBaseCalAmount;
        round.rewardAmount = rewardAmount;

        // Add to treasury
        treasuryAmount = treasuryAmount.add(treasuryAmt);

        emit RewardsCalculated(epoch, rewardBaseCalAmount, rewardAmount, treasuryAmt);
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /**
     * @dev Determine if a round is valid for receiving bets
     * Round must have started and locked
     * Current block must be within startBlock and lockBlock
     */
    function _bettable(uint256 epoch) internal view returns (bool) {
        return
            rounds[epoch].startBlock != 0 &&
            rounds[epoch].lockBlock != 0 &&
            block.number > rounds[epoch].startBlock &&
            block.number < rounds[epoch].lockBlock;
    }
}


// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./DiceToken.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IHeswapRouter02.sol";
import "./libs/IHeswapFactory.sol";
import "./libs/IHeswapPair.sol";

contract Dice is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
	using SafeBEP20 for IBEP20;

	uint256 public prevBankerAmount;
	uint256 public bankerAmount;
	uint256 public netValue;
	uint256 public playerStartEpoch;
    uint256 public currentEpoch;
    uint256 public intervalBlocks;
    uint256 public bufferBlocks;	
	uint256 public playerTimeBlocks;
	uint256 public playerEndBlock;
	uint256 public bankerTimeBlocks;
	uint256 public bankerEndBlock;
    uint256 public constant TOTAL_RATE = 100; // 100%
	uint256 public gapRate = 5;
    uint256 public treasuryRate = 10; // 10% in gap
	uint256 public bonusRate = 10; // 10% in gap
    uint256 public minBetAmount;
	uint256 public totalTreasuryAmount;
	uint256 public constant deadline = 5 minutes;
	uint256 public masterChefPoolId;

    address public adminAddress;
    address public operatorAddress;
	address public masterChefAddress;
	address public swapPairAddress;
	IBEP20 public token;
	IBEP20 public hswToken;
	DiceToken public diceToken;	
	IHeswapRouter02 public swapRouter;

	enum Status {
		Pending,
		Open,
		Lock,
		Claimable,
		Expired
	}

    struct Round {
        uint256 startBlock;
        uint256 lockBlock;
		uint256 secretSentBlock;
		bytes32 bankHash;
        uint256 bankSecret;
        uint256 totalAmount;
		uint256 maxBetAmount;
		uint256[6] betAmounts;
        uint256 treasuryAmount;
        uint256 bonusAmount;
        uint256 bonusHswAmount;
		uint256 betUsers;
		uint32 finalNumber;
		Status status;
    }

    struct BetInfo {
        uint256 amount;
		uint16 numberCount;	
		bool[6] numbers;
        bool claimed; // default false
		bool hswClaimed; // default false
    }

	struct BankerInfo {
		uint256 diceTokenAmount;
		uint256 avgBuyValue;
	}

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(address => uint256[]) public userRounds;
	mapping(address => BankerInfo) public bankerInfo;

    event StartRound(uint256 indexed epoch, uint256 blockNumber, bytes32 bankHash);
    event LockRound(uint256 indexed epoch, uint256 blockNumber);
    event SendSecretRound(uint256 indexed epoch, uint256 blockNumber, uint256 bankSecret, uint32 finalNumber);
    event BetNumber(address indexed sender, uint256 indexed currentEpoch, bool[6] numbers, uint256 amount);
    event Claim(address indexed sender, uint256 indexed currentEpoch, uint256 amount);
    event ClaimBonusHSW(address indexed sender, uint256 amount);
    event ClaimTreasury(uint256 amount);
    event GapRateUpdated(uint256 indexed epoch, uint256 gapRate);
    event RatesUpdated(uint256 indexed epoch, uint256 treasuryRate, uint256 bonusRate);
    event MinBetAmountUpdated(uint256 indexed epoch, uint256 minBetAmount);
    event RewardsCalculated(
        uint256 indexed epoch,
        uint256 treasuryAmount,
        uint256 bonusAmount,
        uint256 bonusHswAmount
    );
	event SwapRouterUpdated(address indexed operator, address indexed router, address indexed pair);
    event EndPlayerTime(uint256 epoch, uint256 blockNumber);
    event EndBankerTime(uint256 epoch, uint256 blockNumber);
    event UpdateNetValue(uint256 epoch, uint256 blockNumber, uint256 netValue);
	event Deposit(address indexed user, uint256 tokenAmount);	
	event Withdraw(address indexed user, uint256 diceTokenAmount);	

    constructor(
		address _tokenAddress,
		address _hswTokenAddress,
		address _diceTokenAddress,
		address _swapRouterAddress,
		address _swapPairAddress,
		address _masterChefAddress,
        address _adminAddress,
        address _operatorAddress,
		uint256 _masterChefPoolId,
        uint256 _intervalBlocks,
        uint256 _bufferBlocks,
		uint256 _playerTimeBlocks,
		uint256 _bankerTimeBlocks,
        uint256 _minBetAmount
    ) public {
		token = IBEP20(_tokenAddress);
		hswToken = IBEP20(_hswTokenAddress);
		diceToken = DiceToken(_diceTokenAddress);
		swapRouter = IHeswapRouter02(_swapRouterAddress);
		swapPairAddress = _swapPairAddress;
		masterChefAddress = _masterChefAddress;
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
		masterChefPoolId = _masterChefPoolId;
        intervalBlocks = _intervalBlocks;
        bufferBlocks = _bufferBlocks;
		playerTimeBlocks = _playerTimeBlocks;
		bankerTimeBlocks = _bankerTimeBlocks;
        minBetAmount = _minBetAmount;
		netValue = uint256(1e12);
		_pause();
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
     * @dev set player time blocks
     * callable by admin
     */
    function setPlayerTimeBlocks(uint256 _playerTimeBlocks) external onlyAdmin {
        playerTimeBlocks = _playerTimeBlocks;
    }

    /**
     * @dev set banker time blocks
     * callable by admin
     */
    function setBankerTimeBlocks(uint256 _bankerTimeBlocks) external onlyAdmin {
        bankerTimeBlocks = _bankerTimeBlocks;
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
    function setRates(uint256 _treasuryRate, uint256 _bonusRate) external onlyAdmin {
        require(_treasuryRate.add(_bonusRate) <= TOTAL_RATE, "Sum of _treasuryRate and _bonusRate must less than TOTAL_RATE");
		treasuryRate = _treasuryRate;
		bonusRate = _bonusRate;

        emit RatesUpdated(currentEpoch, treasuryRate, bonusRate);
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
     * @dev End banker time
     */
    function endBankerTime(uint256 epoch, bytes32 bankHash) external onlyOperator whenPaused {
        require(epoch == currentEpoch + 1, "epoch should equals currentEposh + 1");
        require(bankerAmount > 0, "Round can start only when bankerAmount > 0");
		prevBankerAmount = bankerAmount;
        _unpause();
        emit EndBankerTime(currentEpoch, block.timestamp);
        
        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch, bankHash);
		playerEndBlock = rounds[currentEpoch].startBlock + playerTimeBlocks;
		bankerEndBlock = rounds[currentEpoch].startBlock + bankerTimeBlocks;
    }

    /**
     * @dev Start the next round n, lock for round n-1
     */
    function executeRound(uint256 epoch, bytes32 bankHash) external onlyOperator whenNotPaused nonReentrant {
        require(epoch == currentEpoch, "epoch should equals currentEposh");

        // CurrentEpoch refers to previous round (n-1)
        _safeLockRound(currentEpoch);

        // Increment currentEpoch to current round (n)
        currentEpoch = currentEpoch + 1;
        _safeStartRound(currentEpoch, bankHash);
        require(rounds[currentEpoch].startBlock < playerEndBlock, "startBlock should before playerEndBlock");
        require(rounds[currentEpoch].lockBlock <= playerEndBlock, "lockBlock should before playerEndBlock");
    }

	/**
     * @dev called by the admin to end player time, triggers banker time
     */
    function endPlayerTime(uint256 epoch, uint256 bankSecret) external onlyAdminOrOperator whenNotPaused nonReentrant {
        require(epoch == currentEpoch, "epoch should equals currentEposh");
		sendSecret(epoch, bankSecret);
        _pause();
		_updateNetValue(epoch);
        emit EndPlayerTime(currentEpoch, block.timestamp);
    }

	/**
     * @dev called by the admin to end player time without caring last round
     */
    function endPlayerTimeImmediately(uint256 epoch) external onlyAdminOrOperator whenNotPaused nonReentrant {
        require(epoch == currentEpoch, "epoch should equals currentEposh");
        _pause();
		_updateNetValue(epoch);
        emit EndPlayerTime(currentEpoch, block.timestamp);
    }

	/**
     * @dev called by the operator to update net value
     */
    function _updateNetValue(uint256 epoch) internal onlyOperator whenPaused nonReentrant{	
		netValue = netValue.mul(bankerAmount).div(prevBankerAmount);
		emit UpdateNetValue(epoch, block.timestamp, netValue);
    }

    /**
     * @dev send bankSecret
     */
	function sendSecret(uint256 epoch, uint256 bankSecret) public onlyOperator whenNotPaused nonReentrant {
        require(rounds[epoch].lockBlock != 0, "Can only end round after round has locked");
        require(rounds[epoch].status == Status.Lock, "Can only end round after round has locked");
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
		round.status = Status.Claimable;

        emit SendSecretRound(epoch, block.number, bankSecret, round.finalNumber);
    }

    /**
     * @dev bet number
     */
    function betNumber(bool[6] calldata numbers, uint256 amount) external whenNotPaused notContract nonReentrant {
        require(rounds[currentEpoch].status == Status.Open, "Round not Open");
        require(_bettable(currentEpoch), "Round not bettable");
        require(ledger[currentEpoch][msg.sender].amount == 0, "Can only bet once per round");
		uint16 numberCount = 0;
		for (uint32 i = 0; i < 6; i ++) {
			if (numbers[i]) {
				numberCount = numberCount + 1;	
			}
		}
		require(numberCount > 0, "Count of numbers must greater than 0");
        require(amount >= minBetAmount.mul(uint256(numberCount)), "Bet amount must be greater than minBetAmount mul numberCount");

		token.safeTransferFrom(address(msg.sender), address(this), amount);

        // Update round data
        Round storage round = rounds[currentEpoch];
        round.totalAmount = round.totalAmount.add(amount);
        round.betUsers = round.betUsers.add(1);
		uint256 betAmount = amount.div(uint256(numberCount));
		for (uint32 i = 0; i < 6; i ++) {
			if (numbers[i]) {
				round.betAmounts[i] = round.betAmounts[i].add(betAmount);
			}
		}

        // Update user data
        BetInfo storage betInfo = ledger[currentEpoch][msg.sender];
		betInfo.numbers = betInfo.numbers;
        betInfo.amount = amount;
		betInfo.numberCount = numberCount;
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
        BetInfo storage betInfo = ledger[epoch][msg.sender];
        // Round valid, claim rewards
        if (rounds[epoch].status == Status.Claimable) {
            require(claimable(epoch, msg.sender), "Not eligible for claim");
            reward = betInfo.amount.div(uint256(betInfo.numberCount)).mul(5).mul(TOTAL_RATE.sub(gapRate)).div(TOTAL_RATE);
        }
        // Round invalid, refund bet amount
        else {
            require(refundable(epoch, msg.sender), "Not eligible for refund");
            reward = ledger[epoch][msg.sender].amount;
        }

        betInfo.claimed = true;
		token.safeTransfer(msg.sender, reward);

        emit Claim(msg.sender, epoch, reward);
    }

    /**
     * @dev Claim hsw back
     */
    function claimBonusHSW(address user) external notContract nonReentrant {
		uint256 hswAmount = 0;	
		uint256 epoch;
		uint256 roundHswAmount = 0;
		for (uint256 i = userRounds[user].length - 1; i >= 0; i --){
			epoch = userRounds[user][i];
			BetInfo storage betInfo = ledger[epoch][msg.sender];
			if (betInfo.hswClaimed){
				break;
			}else{
				if (rounds[epoch].status == Status.Claimable){
    				if (betInfo.numbers[rounds[epoch].finalNumber]){
    					roundHswAmount = betInfo.amount.div(uint256(betInfo.numberCount)).mul(5).mul(gapRate).div(TOTAL_RATE).mul(bonusRate).div(TOTAL_RATE);
    					if (betInfo.numberCount > 1){
    						roundHswAmount = roundHswAmount.add(betInfo.amount.div(uint256(betInfo.numberCount)).mul(uint256(betInfo.numberCount - 1)).mul(gapRate).div(TOTAL_RATE).mul(bonusRate).div(TOTAL_RATE));
    					}
    				}else{
    					roundHswAmount = betInfo.amount.mul(bonusRate).div(TOTAL_RATE).mul(rounds[epoch].bonusHswAmount).div(rounds[epoch].bonusAmount);
    				}
    
    				hswAmount = hswAmount.add(roundHswAmount);
    				betInfo.hswClaimed = true;
				}
			}
		}

		hswToken.safeTransfer(user, hswAmount);
        emit ClaimBonusHSW(user, hswAmount);
    }

	/**
     * @dev View pending hsw back
     */
    function pendingBonusHSW(address user) external view returns (uint256) {
        uint256 hswAmount = 0;
        uint256 epoch;
        uint256 roundHswAmount = 0;
        for (uint256 i = userRounds[user].length - 1; i >= 0; i --){
            epoch = userRounds[user][i];
            BetInfo storage betInfo = ledger[epoch][msg.sender];
            if (betInfo.hswClaimed){
                break;
            }else{
				if (rounds[epoch].status == Status.Claimable){
                    if (betInfo.numbers[rounds[epoch].finalNumber]){
                        roundHswAmount = betInfo.amount.div(uint256(betInfo.numberCount)).mul(5).mul(gapRate).div(TOTAL_RATE).mul(bonusRate).div(TOTAL_RATE);
                        if (betInfo.numberCount > 1){
                            roundHswAmount = roundHswAmount.add(betInfo.amount.div(uint256(betInfo.numberCount)).mul(uint256(betInfo.numberCount - 1)).mul(gapRate).div(TOTAL_RATE).mul(bonusRate).div(TOTAL_RATE));
                        }
                    }else{
                        roundHswAmount = betInfo.amount.mul(bonusRate).div(TOTAL_RATE).mul(rounds[epoch].bonusHswAmount).div(rounds[epoch].bonusAmount);
                    }
                    
                    hswAmount = hswAmount.add(roundHswAmount);
				}
            }
        }
		return hswAmount;    
    }

    /**
     * @dev Claim all treasury to masterChef
     * callable by operator
     */
    function claimTreasury() public onlyOperator nonReentrant {
        uint256 currentTreasuryAmount = totalTreasuryAmount;
        totalTreasuryAmount = 0;
		
		token.safeTransfer(masterChefAddress, currentTreasuryAmount);
		// TODO: update masterChef bonus pool

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
            values[i] = userRounds[user][cursor.add(i)];
        }

        return (values, cursor.add(length));
    }

    /**
     * @dev Get the claimable stats of specific epoch and user account
     */
    function claimable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];

        return (round.status == Status.Claimable) && (betInfo.numbers[round.finalNumber]);
    }

    /**
     * @dev Get the refundable stats of specific epoch and user account
     */
    function refundable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];
        return (round.status != Status.Claimable) && block.number > round.lockBlock.add(bufferBlocks) && betInfo.amount != 0;
    }

    /**
     * @dev Start round
     * Previous round n-1 must lock
     */
    function _safeStartRound(uint256 epoch, bytes32 bankHash) internal {
        require(block.number >= rounds[epoch - 1].lockBlock, "Can only start new round after round n-1 lockBlock");
        _startRound(epoch, bankHash);
    }

    function _startRound(uint256 epoch, bytes32 bankHash) internal {
        Round storage round = rounds[epoch];
        round.startBlock = block.number;
        round.lockBlock = block.number.add(intervalBlocks);
		round.bankHash = bankHash;
        round.totalAmount = 0;
		round.status = Status.Open;

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
		rounds[epoch].status = Status.Lock;
        emit LockRound(epoch, block.number);
    }


    /**
     * @dev Calculate rewards for round
     */
    function _calculateRewards(uint256 epoch) internal {
        require(treasuryRate.add(bonusRate) <= TOTAL_RATE, "Sum of treasuryRate and bonusRate must be less than TOTAL_RATE");
        require(rounds[epoch].treasuryAmount == 0, "Rewards calculated");
        Round storage round = rounds[epoch];

		uint256 treasuryAmount = 0;
		uint256 bonusAmount = 0;
		for (uint32 i = 0; i < 6; i ++){
			if (i == round.finalNumber){
				uint256 tmpTreasuryAmount = round.betAmounts[i].mul(5).mul(gapRate).div(TOTAL_RATE).mul(treasuryRate).div(TOTAL_RATE);
				treasuryAmount = treasuryAmount.add(tmpTreasuryAmount);
				uint256 tmpBonusAmount = round.betAmounts[i].mul(5).mul(gapRate).div(TOTAL_RATE).mul(bonusRate).div(TOTAL_RATE);
				bonusAmount = bonusAmount.add(tmpBonusAmount);
				uint256 playerWinAmount = round.betAmounts[i].mul(5).mul(TOTAL_RATE.sub(gapRate)).div(TOTAL_RATE);
				bankerAmount = bankerAmount.sub(playerWinAmount).sub(tmpTreasuryAmount).sub(tmpBonusAmount);
			}else{
				uint256 tmpTreasuryAmount = round.betAmounts[i].mul(gapRate).div(TOTAL_RATE).mul(treasuryRate).div(TOTAL_RATE);
				treasuryAmount = treasuryAmount.add(tmpTreasuryAmount);
				uint256 tmpBonusAmount = round.betAmounts[i].mul(gapRate).div(TOTAL_RATE).mul(bonusRate).div(TOTAL_RATE);
				bonusAmount = bonusAmount.add(tmpBonusAmount);
				uint256 playerLostAmount = round.betAmounts[i];
				bankerAmount = bankerAmount.add(playerLostAmount).sub(tmpTreasuryAmount).sub(tmpBonusAmount);
			}	
		}

		round.treasuryAmount = treasuryAmount;
		round.bonusAmount = bonusAmount;

		if(address(swapRouter) != address(0) && swapPairAddress != address(0)){
			address[] memory path = new address[](2);
			path[0] = address(token);
			path[1] = address(hswToken);
			uint256 hswAmout = swapRouter.swapExactTokensForTokens(round.bonusAmount, 0, path, address(this), block.timestamp + deadline)[1];
			round.bonusHswAmount = hswAmout;
		}
		totalTreasuryAmount = totalTreasuryAmount.add(treasuryAmount);

        emit RewardsCalculated(epoch, round.treasuryAmount, round.bonusAmount, round.bonusHswAmount);
    }

    /**
     * @dev Deposit token to Dice as a banker, get Syrup back.
     */
    function deposit(uint256 _tokenAmount) public whenPaused nonReentrant notContract {
		require(_tokenAmount > 0, "Deposit amount should more than 0");
		BankerInfo storage banker = bankerInfo[msg.sender];
		token.safeTransferFrom(address(msg.sender), address(this), _tokenAmount);
		uint256 diceTokenAmount = _tokenAmount.mul(1e12).div(netValue);
		diceToken.mint(address(msg.sender), diceTokenAmount);
		uint256 totalDiceTokenAmount = banker.diceTokenAmount.add(diceTokenAmount);
		banker.avgBuyValue = banker.avgBuyValue.mul(banker.diceTokenAmount).add(_tokenAmount).mul(1e12).div(totalDiceTokenAmount);
		banker.diceTokenAmount = totalDiceTokenAmount;
		bankerAmount = bankerAmount.add(_tokenAmount);
		emit Deposit(msg.sender, _tokenAmount);	
    }

    /**
     * @dev Withdraw syrup from dice to get token back
     */
    function withdraw(uint256 _diceTokenAmount) public whenPaused nonReentrant notContract {
		require(_diceTokenAmount > 0, "withdraw diceTokenAmount should more than 0");
		BankerInfo storage banker = bankerInfo[msg.sender];
		SafeBEP20.safeTransferFrom(diceToken, msg.sender, address(diceToken), _diceTokenAmount);
		diceToken.burn(address(diceToken), _diceTokenAmount);
		uint256 tokenAmount = _diceTokenAmount.mul(netValue).div(1e12);
		token.safeTransferFrom(address(this), address(msg.sender), tokenAmount);
		banker.diceTokenAmount = banker.diceTokenAmount.sub(_diceTokenAmount);	
		bankerAmount = bankerAmount.sub(tokenAmount);

		emit Withdraw(msg.sender, _diceTokenAmount);
    }

    /**
     * @dev View function to see banker diceToken Value on frontend.
     */
	function canWithdrawToken(address bankerAddress) external view returns (uint256){
		BankerInfo storage banker = bankerInfo[bankerAddress];
		return banker.diceTokenAmount.mul(netValue).div(1e12);	
	}

    /**
     * @dev View function to see banker diceToken Value on frontend.
     */
	function calProfitRate(address bankerAddress) external view returns (uint256){
		BankerInfo storage banker = bankerInfo[bankerAddress];
		return netValue.mul(100).div(banker.avgBuyValue);	
	}

    /**
     * @dev Judge address is contract or not
     */
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

	/**
     * @dev Update the swap router.
     * Can only be called by the current operator.
     */
    function updateSwapRouter(address _router) external onlyOperator {
        swapRouter = IHeswapRouter02(_router);
        swapPairAddress = IHeswapFactory(swapRouter.factory()).getPair(address(token), address(hswToken));
        require(swapPairAddress != address(0), "DICE::updateSwapRouter: Invalid pair address.");
        emit SwapRouterUpdated(msg.sender, address(swapRouter), swapPairAddress);
    }
}


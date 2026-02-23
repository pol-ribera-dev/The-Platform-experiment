// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/*
@title The Platform experiment

@author Pol Ribera Moreno

@notice On-chain survival game inspired by El Hoyo. Players are distributed across 10 floors and compete each round for SurvivorCoin 
tokens descending on a platform. Those with fewer than 100 tokens at the end of the round die. Survivors lose most of their tokens, 
earn an ETH reward, and are reassigned to new floors. The fee to enter is 0.001 ether. The goal is tests cooperation vs selfish behavior.

@dev ERC20 token (OpenZeppelin-based) with restricted transfers (only alive players on the same floor). Rounds, life status, and floor 
assignments are managed on-chain. The contract address acts as the descending platform.Reassignment uses a pseudo-random seed derived 
from player activity.
*/


contract SurvivorCoin is ERC20 {

    //================================================
    //                DATA STRUCTURES
    //================================================
    
    /// @dev Represents a participant, including their current floor
    ///      and the last round for which they have an active life pass.
    struct Participant {
        uint8 floor;
        uint round;
    }


    //================================================
    //                    CONSTANTS
    //================================================

    /// @notice Minimum amount of tokens that a player need to survirvive   
    uint8 constant  TOKENS_PER_PLAYER = 100;

    /// @notice Maximum amount of tokens that a player can carry   
    uint16 constant  MAX_CARRY = 1100;
    
    /// @notice Time to wait before the elevator goes to the next floor
    uint32 constant DURATION = 1 seconds;// 1 days;

    /// @notice Address of the contract's deployer, the comision goes to this one.
    address immutable owner;


    //================================================
    //                STATE VARIABLES
    //================================================

    /// @notice The foor where the elevator is
    /// @dev It is a uint8 because it can not be stronger than 11
    uint8 public actual_floor;

    /// @notice Number of rounds played
    uint public round;

    /// @notice Number of participants alive in the actual round
    uint private num_participants;

    /// @notice Number of participants that buy a pass for the next round
    uint private renewed_participants;
    
    /// @notice Amount of tokens stored by all the alive participants after paying for the pass
    /// This tokens will not return to the elevator.
    uint private tokens_not_returned;
    
    /// @notice Time when the elevator change the floor
    /// @dev it is use to mesure a day before the elevator move again 
    uint private startTime;
    
    /// @notice Seed to calculate pseudo-randomly which floor to place each participant.
    /// @dev It is calculated every time a player takes SurvivorCoin from the elevator, using the 
    /// seed before, the timestamp, the address of the participant and the amount of coins he takes.
    /// The important seed is the one at the end of round.
    uint private seed;
    
    /// @dev Relationates every blockchain address with a participant account 
    mapping (address => Participant) public participants;
    
    
    //================================================
    //               CONSTRUCTOR
    //================================================

    /// @notice Initializes the experiment
    /// @dev It starts in the round 1, with the elevator in floor 11, stores the address that deploy the contract as the owner and 
    /// start the first day count. Also the owner will recive a token to check if the token is created correctly, but it is useless in the experiment.
    /// @param name_  name of the token
    /// @param symbol_ symbol of the token

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        actual_floor = 11;
        startTime = block.timestamp;
        owner = msg.sender;
        _mint(owner, 1);
        round = 1;
    }


    //================================================
    //                  MODIFIERS
    //================================================

    /// @notice Checks that the function that modifies just occurs at maximum one time per day

    modifier oncePerDay() {
        if (block.timestamp > startTime + DURATION){
            startTime = block.timestamp;
            _;
        }
    }


    /// @notice Checks that the participant that calls the function has not entered the experiment yet
    
    modifier notInside() {
        require( participants[msg.sender].floor == 0, "You already in");
        _;
    }


    /// @notice Checks that the participant that calls the function is in the same floor as the elevator

    modifier isInThisFloor() {
        require( participants[msg.sender].floor == actual_floor, "There is nothing to get");
        _;
    }


    /// @notice Checks if that participant is inside the experiment, alive and has not buy the pass yet
    /// @param _participant The participant to be check

    modifier inThisRound(address _participant) {
        require(participants[_participant].round == round, "You are not in this round");
        _;
    }


    /// @notice Checks if it is the time between the end of one round and the start of the next one

    modifier roundEnded() {
        require(actual_floor == 11, "Wait until the end of the round");
        _;
    }


    /// @notice Checks that the reciver can store that amount of tokens
    /// @param _reciver address that recives tokens
    /// @param _value amount of tokens to recive

    modifier maxReciver(address _reciver, uint _value) {
        require(MAX_CARRY - uint16(balanceOf(_reciver)) >= _value, "The reciver can't store that amount");
        _;
    }


    /// @notice Checks if the giver and the reciver are in the same floor
    /// @param _giver address that gives tokens
    /// @param _reciver address that recives tokens

    modifier sameFloor(address _giver, address _reciver) {
        require(participants[_giver].floor == participants[_reciver].floor, "You are not in the same floor");
        _;
    }


    //================================================
    //                   EVENTS
    //================================================

    /// @notice Emitted when the elevator change his floor
    /// @param _floor Is the new floor of the elevator

    event FloorUpdated(uint8 _floor);


    /// @notice Emitted when a new participant enter in the experiment
    /// @param _participant The address of the new participant

    event Entered(address _participant);


    /// @notice Emitted when a participant buys a pass
    /// @param _participant The address of the participant that buys it
    /// @param _actualMoney Amount of money that the participant have after the purchase
    /// @param _newFloor The new floor where the participant is alocated

    event PassBought(address _participant, uint _actualMoney, uint8 _newFloor);


    //================================================
    //              EXTERNAL FUNCTIONS 
    //================================================

    /// @notice Allows an agent to enter the experiment.
    /// @dev The function is payable to discourage bots. The price is arbitrarily set to 1,000,000,000,000,000 wei.
    /// If a user sends more than the required amount, the reward will not be proportional, as this would distort the 
    /// subjective value of token transfers and that mechanism could be exploited.    
    /// The function moves the participant from floor 0 to floor 12 and transfers enough tokens to purchase the pass.
    /// Users may enter once the seed has already been defined. This gives them an advantage,
    /// since they know where they will spawn and may wait for a round with a favorable seed.
    /// However, this advantage only applies to the first round they participate in.
    /// The function does not call updateFloor(), as it would be unfair for someone to enter
    /// and not have enough time to purchase the pass because a new round starts immediately.
    /// Emits {Entered} with the player's address.

    function enter() external payable notInside {
        require(msg.value >= 0.001 ether, "Pay!");
        participants[msg.sender] = Participant(12, round);
        num_participants++;
        _mint(msg.sender, TOKENS_PER_PLAYER);
        emit Entered(msg.sender);
    }


    /// @notice Allows a participant to purchase the Survival Pass for the next round.
    /// @dev To buy the pass the participant has to be alive, have enough tokens and the round has to be ended.
    /// The function transfer the amount of tokens that cost the pass from the participant to the elevator.
    /// Then the round of the participant is incremented, the new floor is calculated (using the seed and his own address) and assigned, 
    /// the reward is payed and the floor is updated. We have the invariant that the participant's balance after the purchase is less 
    /// or equal than 100 (90% of 1100 - 100).
    /// Emits {PassBought} with the player's address, his balance after the purchase and his new floor.

    function buySurvivalPass() external inThisRound(msg.sender) roundEnded{
        require( balanceOf(msg.sender) >= TOKENS_PER_PLAYER, "no tienes suficiente tokens");
        uint16 price = TOKENS_PER_PLAYER + (uint16(balanceOf(msg.sender)) - TOKENS_PER_PLAYER) * 9 / 10 ; //entero
        super.transfer(address(this), price);
        tokens_not_returned += balanceOf(msg.sender);
        participants[msg.sender].round++;
        participants[msg.sender].floor = uint8(uint256(keccak256(abi.encode(seed, msg.sender))) % 10) + 1; 
        renewed_participants++;
        assert(balanceOf(msg.sender) <= TOKENS_PER_PLAYER);
        (bool my_success, ) = payable(owner).call{value: 0.0001 ether}("");
        require(my_success, "Fail payment to me");
        (bool success, ) = payable(msg.sender).call{value: 0.0001 ether}("");
        require(success, "Fail payment");
        updateFloor();
        emit PassBought(msg.sender, balanceOf(msg.sender), participants[msg.sender].floor);  
    }


    /// @notice Allows a participant take an amount of tokens from the elevator.
    /// @dev To call the function the participant has to be alive and in the same floor as the elevator. Also the participant
    /// cannot take more than what there is in the elevator or more than what he can store. We have the invariant that the 
    /// balance of the participant has to be less or equal than the maximum he can store. When it is calculate the amount of 
    /// tokens the participant will take (based in the amount he wants to get, the space left he has and the amount that 
    /// is in the elevator), a trasfer is done of this amount from the elevator to the participant. Then the seed is recalculated
    /// and the elevator floor is updated.
    /// @param _amount The amount of tokens that the participant wants to take. This parameter will never be negative because is unsigned.

    function takeFromElevator(uint16 _amount) external inThisRound(msg.sender) isInThisFloor {

        uint256 tokens_available = balanceOf(address(this));
        uint16 userBalance = uint16(balanceOf(msg.sender));
        assert(MAX_CARRY >= userBalance);
        uint16 spaceLeft = MAX_CARRY - userBalance;

        if (tokens_available < _amount) _amount = uint16(tokens_available);

        if (_amount > spaceLeft) _amount = spaceLeft;
        
        require(_amount > 0, "Nada que coger");
        _transfer(address(this), msg.sender, _amount);

        seed = uint256(keccak256(abi.encode(seed, block.timestamp, _amount, msg.sender)));

        updateFloor();
    }
    

    /// @notice function to receive donations and generate a pool.

    receive() external payable {}


    //================================================
    //               PUBLIC FUNCTIONS 
    //================================================

    /// @notice Returns the number of decimals the token uses. Always returns 0, so the token cannot have any decimal.
    /// @dev Overrides the ERC20 decimals function to return 0.
    
    function decimals() public pure override returns (uint8) {
        return 0;
    }


    /// @notice Transfers tokens applying additional system restrictions.
    /// @dev Overrides the ERC20 transfer function to force that the two participants are alive, 
    /// are in the same floor and that the reciver have enough space to recive that amount of tokens.
    /// If all conditions are satisfied, execution is delegated to the parent ERC20 transfer implementation.

    function transfer(address to, uint256 value) public override inThisRound(to) inThisRound(msg.sender) sameFloor(msg.sender, to) maxReciver(to, value) returns (bool) {
        return super.transfer(to, value);
    }
    

    /// @notice Transfers tokens applying additional system restrictions.
    /// @dev Overrides the ERC20 transferFrom function to force that the two participants are alive, 
    /// are in the same floor and that the reciver have enough space to recive that amount of tokens.
    /// If all conditions are satisfied, execution is delegated to the parent ERC20 transferFrom implementation.

    function transferFrom(address from, address to, uint256 value) public override maxReciver(to, value) sameFloor(from, to) inThisRound(to) inThisRound(from) returns (bool) {
        return super.transferFrom(from, to, value);
    }

   
    /// @notice Updates the floor of the elevator.
    /// @dev It can just be called once per day, and increments by one the variable actual_floor, that 
    /// represents the actual floor of the elevator. When it arrives to the 12 floor, and the StartRound
    /// function is called, so the elevator goes to floor one again. 
    /// Emits {FloorUpdated} with the new floor of the elevator.

    function updateFloor() public oncePerDay{
        actual_floor++;
        if(actual_floor == 12){
            startRound();
        }
        emit FloorUpdated(actual_floor);
    }


    //================================================
    //              INTERNAL FUNCTIONS 
    //================================================

    /// @notice Sets the start of the round and rebalances the elevator to force that the total
    /// number of tokens is exactly the number needed for all participants to survive.
    /// @dev To achive that, it are minted to the elevator the tokens that are stored by dead people and
    /// then, it are burned the tokens that in the last round corresponded to people that now are dead.
    /// It is imposible to fail, because the maximum that someone can store is TOKENS_PER_PLAYER, so in the
    /// worse case all the new participants will have 100 tokens and in the elevator there will be 0. 
    /// Finaly the elevator goes to floor 1 and the experiment goes to the next round.

    function startRound() internal {
        
        uint dead_participants = num_participants - renewed_participants;
        uint tokenes_to_burn = dead_participants * TOKENS_PER_PLAYER;
        uint dead_tokens = num_participants * TOKENS_PER_PLAYER - balanceOf(address(this)) - tokens_not_returned;
        
        num_participants = renewed_participants;
        tokens_not_returned = 0;
        renewed_participants = 0; 
        
        _mint(address(this), dead_tokens);
        
        _burn(address(this), tokenes_to_burn);

        actual_floor = 1;
        round++;                 
    }

}

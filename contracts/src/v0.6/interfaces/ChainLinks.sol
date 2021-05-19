// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.6/interfaces/AggregatorV2V3Interface.sol";
contract Owned {

    address public owner;
    address private pendingOwner;

    event OwnershipTransferRequested(
        address indexed from,
        address indexed to
    );
    event OwnershipTransferred(
        address indexed from,
        address indexed to
    );

    constructor() public {
        owner = msg.sender;
    }

    /**
     * @dev Allows an owner to begin transferring ownership to a new address,
     * pending.
     */
    function transferOwnership(address _to)
    external
    onlyOwner()
    {
        pendingOwner = _to;

        emit OwnershipTransferRequested(owner, _to);
    }

    /**
     * @dev Allows an ownership transfer to be completed by the recipient.
     */
    function acceptOwnership()
    external
    {
        require(msg.sender == pendingOwner, "Must be proposed owner");

        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /**
     * @dev Reverts if called by anyone other than the contract owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Only callable by owner");
        _;
    }

}

contract AggregatorProxy is AggregatorV2V3Interface, Owned {

    struct Phase {
        uint16 id;
        AggregatorV2V3Interface aggregator;
    }

    Phase private currentPhase;
    AggregatorV2V3Interface public proposedAggregator;
    mapping(uint16 => AggregatorV2V3Interface) public phaseAggregators;

    uint256 constant private PHASE_OFFSET = 64;
    uint256 constant private PHASE_SIZE = 16;
    uint256 constant private MAX_ID = 2 ** (PHASE_OFFSET + PHASE_SIZE) - 1;

    constructor(address _aggregator) public Owned() {
        setAggregator(_aggregator);
    }

    /*
    最新答案
    */
    function latestAnswer() public view virtual override returns (int256 answer){
        return currentPhase.aggregator.latestAnswer();
    }

    /*
    最新时间戳
    */
    function latestTimestamp() public view virtual override returns (uint256 updatedAt){
        return currentPhase.aggregator.latestTimestamp();
    }

    /*
    得到答案
    */
    function getAnswer(uint256 _roundId) public view virtual override returns (int256 answer){
        if (_roundId > MAX_ID) return 0;

        (uint16 phaseId, uint64 aggregatorRoundId) = parseIds(_roundId);
        AggregatorV2V3Interface aggregator = phaseAggregators[phaseId];
        if (address(aggregator) == address(0)) return 0;

        return aggregator.getAnswer(aggregatorRoundId);
    }

    function getTimestamp(uint256 _roundId) public view virtual override returns (uint256 updatedAt){
        if (_roundId > MAX_ID) return 0;

        (uint16 phaseId, uint64 aggregatorRoundId) = parseIds(_roundId);
        AggregatorV2V3Interface aggregator = phaseAggregators[phaseId];
        if (address(aggregator) == address(0)) return 0;

        return aggregator.getTimestamp(aggregatorRoundId);
    }


    function latestRound() public view virtual override returns (uint256 roundId){
        Phase memory phase = currentPhase;
        // cache storage reads
        return addPhase(phase.id, uint64(phase.aggregator.latestRound()));
    }

    function getRoundData(uint80 _roundId) public view virtual override returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound){
        (uint16 phaseId, uint64 aggregatorRoundId) = parseIds(_roundId);
        (
        roundId,
        answer,
        startedAt,
        updatedAt,
        answeredInRound
        ) = phaseAggregators[phaseId].getRoundData(aggregatorRoundId);

        return addPhaseIds(roundId, answer, startedAt, updatedAt, answeredInRound, phaseId);
    }


    function latestRoundData() public view virtual override returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound){
        Phase memory current = currentPhase;
        // cache storage reads

        (
        roundId,
        answer,
        startedAt,
        updatedAt,
        answeredInRound
        ) = current.aggregator.latestRoundData();

        return addPhaseIds(roundId, answer, startedAt, updatedAt, answeredInRound, current.id);
    }


    function proposedGetRoundData(uint80 _roundId) public view virtual hasProposal() returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound){
        return proposedAggregator.getRoundData(_roundId);
    }


    function proposedLatestRoundData() public view virtual hasProposal() returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound){
        return proposedAggregator.latestRoundData();
    }

    function aggregator() external view returns (address){
        return address(currentPhase.aggregator);
    }

    function phaseId() external view returns (uint16){
        return currentPhase.id;
    }


    function decimals() external view override returns (uint8){
        return currentPhase.aggregator.decimals();
    }


    function version() external view override returns (uint256){
        return currentPhase.aggregator.version();
    }


    function description() external view override returns (string memory){
        return currentPhase.aggregator.description();
    }


    function proposeAggregator(address _aggregator) external onlyOwner() {
        proposedAggregator = AggregatorV2V3Interface(_aggregator);
    }


    function confirmAggregator(address _aggregator) external onlyOwner() {
        require(_aggregator == address(proposedAggregator), "Invalid proposed aggregator");
        delete proposedAggregator;
        setAggregator(_aggregator);
    }


    function setAggregator(address _aggregator) internal {
        uint16 id = currentPhase.id + 1;
        currentPhase = Phase(id, AggregatorV2V3Interface(_aggregator));
        phaseAggregators[id] = AggregatorV2V3Interface(_aggregator);
    }

    function addPhase(uint16 _phase, uint64 _originalId) internal pure returns (uint80){
        return uint80(uint256(_phase) << PHASE_OFFSET | _originalId);
    }

    function parseIds(uint256 _roundId) internal pure returns (uint16, uint64){
        uint16 phaseId = uint16(_roundId >> PHASE_OFFSET);
        uint64 aggregatorRoundId = uint64(_roundId);
        return (phaseId, aggregatorRoundId);
    }

    function addPhaseIds(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound, uint16 phaseId) internal pure returns (uint80, int256, uint256, uint256, uint80){
        return (
        addPhase(phaseId, uint64(roundId)),
        answer,
        startedAt,
        updatedAt,
        addPhase(phaseId, uint64(answeredInRound))
        );
    }


    modifier hasProposal() {
        require(address(proposedAggregator) != address(0), "No proposed aggregator present");
        _;
    }

}

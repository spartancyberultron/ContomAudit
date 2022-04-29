pragma solidity ^0.5.2;

///=== IMPORTS & INTERFACES =====
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@chainlink/contracts/src/v0.5/ChainlinkClient.sol";
import "./OtonomiBasics.sol";
import "./oraclize/oraclizeAPI.sol";

contract MSC_Interface { //Using an interface to interact with the MSC
    function updateFromOracle(bytes32 _policyId, bytes32 _flightId, int256 _actualArrDte, uint8 _fltStatus) public;
}

///=== CONTRACT CODE =====
contract Otonomi_Chainlink is ChainlinkClient, usingOtonomiBasics, usingOraclize { //inherits  Ownable, Authorizable
    using SafeMath for uint; 

    //-- EVENTS:
    event LogArrivalUpdated(string _fltNum, int256 actualArrDte, uint256 flightDelayCalc);
    event LogNewChainlinkQuery(bytes32 query);
    event LogCallbackChainlink(bytes32 query, int256 actualArrDte);
    event ChainlinkActionNeeded(bytes32 policyId, bytes32 queryId, int256 returnValue);

    //replace it by the ones at the top for each new contract
    address private chainlinkOracleAddr = 0x2f90A6D021db21e1B2A077c5a37B3C7E75D15b7e;
    bytes32 private dataJobId = 0xa644d4e30977459d9a596bef89c09e7100000000000000000000000000000000;
    bytes32 private sleepJobId = 0xf0003b2c52024e7fa931d6ee9a947c8700000000000000000000000000000000;

    //MANUAL OVERRIDE of the ORACLE FUNCTION
    bool public _MSC_update = true; //blocks MSC update. For testing of the Chainlink solution

    //-- STRUCTS & MAPPINGS:
    //Policies:
    struct PolicyInformation {  //key = policyId.
        address originAddress;  //MSC source of the _policyId
        bytes32 policyId;       //duplicate used for REMIX interactions (view the struct)
        bytes32 flightId;       //fight Id (can be resolved from fltNum and depDte)
        bytes32 queryId;        //Chainlink queryId
    }
    mapping (bytes32 => PolicyInformation) public Policies; //list of all the Oracle queries,see struct for details.
    bytes32[] public ArrayOfPolicies; //logs all the policies 1 policyId = 1 queryId = flightId

    //Flights:
    struct FlightInformation{ //key = _FlightId aiming at this flight.
        string fltNum; //name of the flight
        uint256 depDte; //departure date (local time)
        uint256 expectedArrDte; //expected arrival time (given when calling function)
        int256 actualArrDte; //Actual arrival date (updated when <> 0, local time)
        uint256 calculatedDelay; //delay calculated form variables (redundant info for tests)
        uint8 fltSts; //flight status (0=unknown, 1=on-time, 2=delay, 3=other). Updated by Oracle or manually //chainlink queryID (appears once actualArrDte is updated)
    }
    
    mapping (bytes32 => FlightInformation) public Flights; //list of all the flights updated by this Oracle, see struct for details. //note: we can use Flightaware FlightID in the future.
    bytes32[] public ArrayOfFlights; //logs all the Flights

    uint256 internal oracleFee; // chainlink payment 

    //Queries:
    struct QueryInformation {   //key = queryId
        bytes32 policyId;       //policy being resolved
        bool pendingQuery;      //true = query not
        uint256 lastUpdated;
    }   //blocks.timestamp
    mapping (bytes32 => QueryInformation) public Queries;
    //no array needed here (do we need to count ?)

    //MANUAL OVERRIDE:
    uint8 public PAYMT = 4; //used to stop operations from the callback (see MSC code)
                        //default = 4, the full set of operations
    function ___UDATEPAYMENT(uint8 _value) public onlyOwner {
        PAYMT = _value;
    } //allows to test different callback scenarions. PAYMT = 0 to 4 (0 manual step by step), 4= full payment)


    //-- SETUP functions:
    function() external payable {} //callback

    constructor() public {
        //require (msg.value > 0); //send ETH to be able to pay Chainlink.
        addAuthorized(msg.sender); // not needed ?
        setPublicChainlinkToken();
        oracleFee = 0.1 * 10 ** 18;
    }


    //-- ORACLE functions:

    function triggerOracle(
        bytes32 _policyId,
        string memory _flight,
        uint256 _departure,
        uint256 _expectedArrival,
        uint256 _updateDelayTime,
        address _MSCaddress
    ) 
        public
        onlyAuthorized
    {
        //create temporary _flightId & update variables (calls chainlink if variable _Chainlink != 0)
        bytes32 _flightId = createFlightId(_flight, _departure); //using Otonomi_Basics method

    //update of our internal mappings: Policy and Flights
        ArrayOfPolicies.push(_policyId);
        Policies[_policyId].originAddress = _MSCaddress; //required for callback activation
        Policies[_policyId].flightId = _flightId;  //updates queries database

        ArrayOfFlights.push(_flightId);
        Flights[_flightId].fltNum = _flight;
        Flights[_flightId].depDte = _departure;
        Flights[_flightId].expectedArrDte = _expectedArrival; //for tests & manual input

        // request takes a JobID, a callback address, and callback function as input
        Chainlink.Request memory req = buildChainlinkRequest(sleepJobId, address(this), this.fulfill.selector);
        req.add("flight", _flight);
        req.addUint("departure", _departure);
        req.addUint("until", _updateDelayTime);
        
        // Sends the request with the amount of payment specified to the oracle (results will arrive with the callback = later)
        bytes32 _queryId = sendChainlinkRequestTo(chainlinkOracleAddr, req, oracleFee);
        
        emit LogNewChainlinkQuery(_queryId);

        //update of Queries and Policies:
        Queries[_queryId].policyId = _policyId;
        Queries[_queryId].pendingQuery = true;   //"true" = query is pending (chainlink did not answer back)
        Queries[_queryId].lastUpdated = 0;       //not yet updated

        Policies[Queries[_queryId].policyId].queryId = _queryId;  //direct use of _policyId GENERATES "STACK TOO DEEP"
    }

    int256 public result;

    function fulfill(
        bytes32 _requestId,
        int256 _result
    )
        public
        recordChainlinkFulfillment(_requestId)
    {
        if(_MSC_update == true) {
            updateMSC(_requestId, _result);
        }
        _MSC_update = true;
    }

    function updateMSC(bytes32 queryId, int256 _result) internal {
        int256 actualArrDte = _result;
        bytes32 _policyId = Queries[queryId].policyId;
        
        Policies[_policyId].queryId = queryId;  //updates Policies database
        Queries[queryId].pendingQuery = false; // This effectively marks the queryId as processed.
        Queries[queryId].lastUpdated = block.timestamp; //note: we could use block.number too

        if (actualArrDte == 0) {
            emit ChainlinkActionNeeded(_policyId, queryId, _result);
            return;
        }
        
        bytes32 _flightId = Policies[_policyId].flightId; //retrieve the flightId from the queryId

        (uint256 _flightDelay, uint8 _fltSts) = updateFlightDelay(actualArrDte, Flights[_flightId].expectedArrDte);
        Flights[_flightId].actualArrDte = actualArrDte;
        Flights[_flightId].calculatedDelay = _flightDelay;
        Flights[_flightId].fltSts = _fltSts;

        emit LogArrivalUpdated(Flights[_flightId].fltNum, actualArrDte, _flightDelay);

        //send info into MSC, use public variable to trigger functions or not
        if (PAYMT > 0) {
            MSC_Interface(Policies[_policyId].originAddress).updateFromOracle(_policyId, _flightId, actualArrDte, _fltSts);
        }

    } //real chainlink callback.

//-- ADMIN functions
    function killContract() public onlyAuthorized {
        selfdestruct(msg.sender); 
    }

    function withdrawTokens(address _tokenAddress) public onlyOwner returns (uint256 _withdrawal) {
        _withdrawal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(msg.sender, _withdrawal);
    }

    function changeOracleFee(uint256 _newFee) public onlyAuthorized {
        require(_newFee > 0, "Oracle payment must be greater than 0");
        oracleFee = _newFee;
    }

//-- TESTING functions
    function ___getInfoFromPolicy(bytes32 _policyId) public view returns (
        string memory fltNum,
        uint256 depDte,
        uint256 expectedArrDte,
        int256 actualArrDte,
        uint256 fltSts,
        uint256 calculatedDelay,
        bool _pendingQuery,
        uint256 _dateLastUpdated
    ) {
        bytes32 _flightId = Policies[_policyId].flightId;
        bytes32 _queryId = Policies[_policyId].queryId;

        return(
            Flights[_flightId].fltNum,
            Flights[_flightId].depDte,
            Flights[_flightId].expectedArrDte,
            Flights[_flightId].actualArrDte,
            Flights[_flightId].fltSts,
            Flights[_flightId].calculatedDelay,
            Queries[_queryId].pendingQuery,   //"true" = query is pending (chainlink did not answer back)
            Queries[_queryId].lastUpdated
        );
    }
///=== END OF CODE =====
}

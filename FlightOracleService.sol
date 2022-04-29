pragma solidity ^0.5.0;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "./FlyionBasics.sol";

contract MSC_Interface {
    function updateFromOracle(bytes32 _policyId, bytes32 _flightId, int256 _actualArrDte, uint8 _fltStatus) public;
}

contract FlightOracleService is usingFlyionBasics {
    uint256 private requestCount = 1;

    event LogNewFlightServiceQuery(
        bytes32 _queryId,
        bytes32 _policyId,
        string _flight,
        uint256 _departure,
        uint256 _expectedArrival,
        uint256 _updateDelayTime,
        address _MSCaddress
    );
    event LogArrivalUpdated(bytes32 _queryId, string _fltNum, int256 actualArrDte, uint256 flightDelayCalc);

    struct QueryInformation {
        bytes32 policyId;
        bool pendingQuery;
        uint256 lastUpdated;
    }
    mapping (bytes32 => QueryInformation) public Queries;

    struct PolicyInformation {
        address originAddress;
        bytes32 policyId;
        bytes32 flightId;
        bytes32 queryId;
    }
    mapping (bytes32 => PolicyInformation) public Policies;

    struct FlightInformation {
        string fltNum;
        uint256 depDte;
        uint256 expectedArrDte;
        int256 actualArrDte;
        uint256 calculatedDelay;
        uint8 fltSts;
    }
    mapping (bytes32 => FlightInformation) public Flights;

    constructor() public {
    }

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
        bytes32 _flightId = createFlightId(_flight, _departure);

        Policies[_policyId].originAddress = _MSCaddress;
        Policies[_policyId].flightId = _flightId;

        Flights[_flightId].fltNum = _flight;
        Flights[_flightId].depDte = _departure;
        Flights[_flightId].expectedArrDte = _expectedArrival;

        bytes32 queryId = keccak256(abi.encodePacked(this, requestCount));
        requestCount += 1;

        emit LogNewFlightServiceQuery(queryId, _policyId, _flight, _departure, _expectedArrival, _updateDelayTime, _MSCaddress);

        Queries[queryId].policyId = _policyId;
        Queries[queryId].pendingQuery = true;
        Queries[queryId].lastUpdated = 0;

        Policies[Queries[queryId].policyId].queryId = queryId;
    }

    function fulfill(
        bytes32 _requestId,
        int256 _result
    )
    public
    {
        updateMSC(_requestId, _result);
    }

    function updateMSC(bytes32 queryId, int256 _result) internal {
        int256 actualArrDte = _result;
        bytes32 _policyId = Queries[queryId].policyId;

        Policies[_policyId].queryId = queryId;
        Queries[queryId].pendingQuery = false;
        Queries[queryId].lastUpdated = block.timestamp;

        bytes32 _flightId = Policies[_policyId].flightId;

        (uint256 _flightDelay, uint8 _fltSts) = updateFlightDelay(actualArrDte, Flights[_flightId].expectedArrDte);
        Flights[_flightId].actualArrDte = actualArrDte;
        Flights[_flightId].calculatedDelay = _flightDelay;
        Flights[_flightId].fltSts = _fltSts;

        emit LogArrivalUpdated(queryId, Flights[_flightId].fltNum, actualArrDte, _flightDelay);

        MSC_Interface(Policies[_policyId].originAddress).updateFromOracle(_policyId, _flightId, actualArrDte, _fltSts);
    }
}

pragma solidity ^0.5.0;

///=== INTRODUCTION ====
/*

    Gas LIMIT by default in REMIX is too small. (contract = 4,657,843 gas)
    Note: current ETH mainnet limit is 8,003,923 (23 June 2019)

TESTING:
----------------------------------------------------------

1- [0x]SETUP contracts

TKN: 0xdcb182bd7058d319a339baebf6e8b65fc9d40873
ORC: 0xA85d02D443dE6990067ED011DeCc9b9e0719d8ce

MSC: 0x378B36062D92B1B7C7e32Ba6a0e627E332459E57

2- [TKN]SEND TOKENS TO MSC
3- [ORC]AUTHORIZE MSC in ORACLE contract

4- [MSC]CREATE POLICY    "AFR","100001","150001","600","10","200","2345678910","10"

policy : 0x906ca1323a687ffb08ea4cf907be15a83938607d879b8943c3216b3155ad95f5
flight : 0x2c8353deb12bd046b8cd4a8863afb0ee20dd73e34edb39e2e8b0cfd2bceaac33

5- [MSC]ACTIVATE POLICY
    _updateDelayTime = 0 will ask for callback 10min after _expectedArrDte
    [ORK] check how flight is written into the ORACLIZE variables, get queryId.

6- [TKN]BUY POLICY

7- [MSC]CHECK VARIABLES UPDATE
    policyDetails struct:
        nbClients, nbSeatsSold
        policyStatus = 1

    MasterPolicy struct:
        nbPolicies
        collateralRequired = OK

    tokenBalance:
        should cover collateral requirements


8- [ORC]SIMULATE CALLBACK with uintCallback function, test = 0 (will trigger token transfer)
    _MSCaddress required

    6a- from [ORC]
    6b- form external [0x]


*/
///=====================


///=== IMPORTS =====
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./OtonomiBasics.sol";

///=== INTERFACES & CONTRACTS ===== used to query the other smartcontracts (using their address as parameter)

contract OtonomiOracle_Interface { //Using an interface to interact with the Chainlink (or Oraclize) address (no need to recompile the whole thing)
    function triggerOracle(bytes32 _policyId, string memory _fltNum, uint256 _depDte, uint256 _expectedArrDte, uint256 _updateDelayTime, address _MSCaddress) public;
}

contract IEscrow { //Using an interface to interact with the Oraclize address (no need to recompile the whole thing)
    function withdrawTokens(address _recipient, uint256 _value) public;
    function addClientPayment(address client, uint amount, bytes32 policyId, uint claimPayouts) external;
    function processInsurancePayment(address client, bytes32 policyId) external;
    function transferOwnership(address newOwner) public;
}

///=== CONTRACT =====
contract MSC is Ownable, Authorizable, usingOtonomiBasics { //remove Ownable? Check bytesize
    using SafeMath for uint256;

    ///--- EVENTS:
    event LogString(string);
    event LogUint256(string, uint256 number);
    event LogBytes32(string, bytes32 identifier);
    event LogAddress(string, address);
    event LogPurchasedProduct(address client, uint256 premiumPaid, bytes32 product);
    event PaymentDue(uint nbCustomers, bytes32 policyId, bytes32 flightId, int256 actualArrDte, uint8 fltStatus);
    event NoClaim(uint nbCustomers, bytes32 policyId, bytes32 flightId, int256 actualArrDte, uint8 fltStatus);
    ///--- STRUCTS & MAPPINGS:

    //masterpolicies------------------------------
    struct MasterPolicy {           //The MasterPolicy is a riskclass bucket, this is what gets funded in TOKENS
        uint8 nbPolicies;           //Total mb of nbPolicies in the MSC. ACTIVE ONES ONLY
        uint256 MaxCollateralRequired; //assuming all seats are sold
        uint256 collateralRequired; //Amount of collateral required to pay all the customers
    }

    //flights------------------------------
    struct FlightDetail {
        string fltNum; //name of the flight
        uint256 depDte; //departure date (local time)
        uint256 expectedArrDte; //expected arrival date (local time)
        int256 actualArrDte; //actual Arrival Date given by Oracle
        uint8 fltStatus; //flight status (0=unknown, 1=on-time, 2=delayed, 3=cancelled, 4=other). Updated by Oracle or manually during tests
    }

    struct PolicyDetail { // ONE (1) policy = 1 flight  details
        //info
        bytes32 flightId;       // flightId that this policy is targetting (1 per policy)
        uint256 dlyTime;        // delay class proposed (45 or 180min)
        uint256 premium;        // product price. Can be recalibrated
        uint256 claimPayout;    // needs to be recalibrated: from AWS or from ETH -> Claim payment = in the subscription contract
                                // AWS way: means subscription can be ONLY from AWS (not open)
                                // AWS way : requires to segregate addresses & keys -> Creation/Modification/Cancellation vs. Subscription
                                // ETH way : requires a recalibration function (ownerOnly). DO 1st.
        uint expiryDte;         // expiry date of the policy

        //customers
        uint256 nbClients;
        uint256 nbSeatsMax;        //max nb of seats open on this policy
        uint256 nbSeatsSold;    // nbSeats open on this policy

        //control
        //uint rskCls;            //number between 1 and 10 = risk class (replaces "Hi", "Lo")
        uint8 policyStatus;       //0= created and locked, 1= active for subscription, 2= oracle answered (=payment), 3= payment processed
        uint256 claimPayoutBlock; //block# payout has been paid (traceability)
    }

    bytes32 flightId; //Hash of (fltNum, detDte), to be used with OtonomiOraclize_Interface
    mapping(bytes32 => FlightDetail) public flightDetails;

    bytes32 policyId; //Hash of (flightId, dlyTime, premiumm, rskCls), used to identify policies and flights
    mapping(bytes32 => PolicyDetail) public policyDetails;

    bytes32[] public ArrayOfPolicies; //to count them and find them easily with this function:

    mapping (uint8 => MasterPolicy) public masterPolicy; //instiantiates the masterPolicies
    //Note: we can setup 128 MasterPolicies in the MSC, we limit to 1 at the moment using masterPolicy[0] in the code


    //--customers
    struct clientsSubscription {
        uint256 datePurchased;
        uint256 premiumPaid;
        uint256 claimPaid; //claimPayout at the moment of the subscription
        uint256 claimPayout;
        uint256 nbSeatsPurchased; //how many this client bought on this policy
    }

    //client subscriptions:
    mapping(address => mapping(bytes32 => clientsSubscription)) public clientsSubscriptions; //key = customers addresses
    //3d mapping (matrix)

    mapping(bytes32 => address[]) public ListOfCustomers; //per policyId
    mapping(address => bytes32[]) public ListofPoliciesSubscribed; //per client address


    //--- Public variables
    address public MscOwner;
    address public oracleAddress; //will be payable in real

    //MANUAL OVERRIDE:
    uint8 public PAYMT = 4; //used to stop operations from the callback (see MSC code)
                        //default = 4, the full set of operations
    function ___UDATEPAYMENT(uint8 _value) public onlyOwner {
        PAYMT = _value;
    } //allows to test different callback scenarions. PAYMT = 0 to 4 (0 manual step by step), 4= full payment)



    //--- MODIFIERS
    modifier onlyOracle() {
        require(msg.sender == oracleAddress || msg.sender == MscOwner, "only Oracle or Owner can use this function");
        _;
    }

    modifier flightExists(bytes32 _flightId) {
        require(flightDetails[_flightId].depDte > 0 , "Flight does not exist");
        _;
    }

    modifier policyExists(bytes32 _policyId) {
        require(policyDetails[_policyId].flightId[0] != 0 , "Policy does not exist"); //TODO: This breaks if flight ID starts with 0!
        _;
    }

    modifier policyBindedToFlight(bytes32 _policyId, bytes32 _flightId) {
        require(flightDetails[_flightId].depDte > 0 , "Flight does not exist");
        require(policyDetails[_policyId].flightId[0] != 0 , "Policy does not exist");
        require(policyDetails[_policyId].flightId == _flightId , "Policy not attached to Flight");
        _;
    }

    modifier policySoldSeats(bytes32 _policyId) {
        require(policyDetails[_policyId].nbSeatsSold > 0 , "ZERO seats sold");
        _;
    }

    modifier policyPurcheasable(bytes32 _policyId) {
        require(policyDetails[_policyId].policyStatus == 1, "Policy is not Active");
        require(policyDetails[_policyId].expiryDte > block.timestamp-60, "EXPIRED!"); //60sec margin
        require(policyDetails[_policyId].nbSeatsSold < policyDetails[_policyId].nbSeatsMax, "SOLD OUT!");
        _;
    }

    modifier clientPurchasedPolicy(address _client, bytes32 _policyId) {
        require(clientsSubscriptions[_client][_policyId].nbSeatsPurchased > 0 , "Policy not purchased by client");
        _;
    }

    modifier policyCanProcessPayment(bytes32 _policyId) { //can process payment
        require(policyDetails[_policyId].claimPayoutBlock == 0, "Policy payout already happened - INFORMATION");
        require(policyDetails[_policyId].policyStatus == 2,"Policy status is NOT awaiting payment - INFORMATION");
        require(policyDetails[_policyId].nbSeatsSold >= 1, "ZERO seats sold for this Policy - INFORMATION");
        _;
    }

    modifier clientEligibleToClaim(address _client, bytes32 _policyId) {
        require(_client != address(0), "Client address is 0x");
        require(clientsSubscriptions[_client][_policyId].claimPaid == 0, "Client already got paid");
        require(clientsSubscriptions[_client][_policyId].nbSeatsPurchased > 0, "Client did not purchase seats");
        _;
    }


    //--- CONSTRUCTOR:
    constructor(address _orcAdr) public  {
        MscOwner = msg.sender;
        oracleAddress = _orcAdr;

        //Initializes the masterPolicy details (always at ZERO)
        masterPolicy[0].nbPolicies = 0;
        masterPolicy[0].collateralRequired = 0; //not needed (can be calculated) but required for control

        //Authorize contracts to interact with MSC
        addAuthorized(oracleAddress);   //needed for the policy update by oracle (only authorized)
        emit LogString("MSC constructor executed");
    }

    //--- POLICY CREATION:
    //ADMIN: Create a Policy
    function createPolicy(
        string memory _fltNum,      // flightName (string that is FlightAware compatible)
        uint256 _depDte,            // departure date
        uint256 _expectedArrDte,    // arrival date (estimated, can be ZERO at this stage)
        uint256 _dlyTime,           // it's the product Class (example: 45 min or 180min delay)
        uint256 _premium,           // premium for the 45min entry (180min = _premium x2 at this stage)
        uint256 _claimPayout,       // claim payout (if flight is late). Initial instance beofre any recalibration
        uint256 _expiryDte,         // expiration date of the Policy
        uint256 _nbSeatsMax         // nb of seats open on this flight
    ) public onlyOwner
    returns(bytes32 __policyId) {

        if (_expiryDte == 0) {
            _expiryDte = _expectedArrDte - 3600*24*7;
        } //default = 2 weeks before flight arrival

        //calculate
        bytes32 _flightId = createFlightId(_fltNum, _depDte); //Id of the flights
        bytes32 _policyId = createPolicyId(_fltNum, _depDte, _expectedArrDte, _dlyTime, _premium, _claimPayout, _expiryDte, _nbSeatsMax); //Id of the Policy

        // require policy not to already exists
        require(policyDetails[_policyId].flightId != _flightId , "Policy already exists"); //we check if the policy exists

        //update of flight details, using flightId:
        flightDetails[_flightId].fltNum = _fltNum;      //creates an entry in the mapping for this policyID
        flightDetails[_flightId].depDte = _depDte;
        flightDetails[_flightId].expectedArrDte = _expectedArrDte;
        flightDetails[_flightId].actualArrDte = 0;      //unkown at this stage
        flightDetails[_flightId].fltStatus = 0;         //unkown at this stage (0=unknown, 1=on-time, 2=delay, 3=other)

        //update of policy details, using policyId:
        policyDetails[_policyId].flightId = _flightId;  //1 policy => 1 flight, but 1 flight can have multiple policies
        policyDetails[_policyId].dlyTime = _dlyTime;
        policyDetails[_policyId].premium = _premium;
        policyDetails[_policyId].claimPayout = _claimPayout;
        policyDetails[_policyId].expiryDte = _expiryDte;

        policyDetails[_policyId].nbSeatsMax = _nbSeatsMax;

        policyDetails[_policyId].policyStatus = 0;      //policy is created but inactive by default, need to activate it.
        policyDetails[_policyId].claimPayoutBlock = 0;  //initialized

        ArrayOfPolicies.push(_policyId);        //update ArrayOfpolicyDetails

        emit LogBytes32("Policy created", _policyId);
        return (_policyId);
    }


    //ADMIN: Activate a policy = triggers Oracle

    function forcePolicyStatus(bytes32 _policyId , uint8 _policyStatus) public onlyOwner {
        policyDetails[_policyId].policyStatus = _policyStatus;
        if(_policyStatus == 0) {
            masterPolicy[0].nbPolicies --;
            masterPolicy[0].MaxCollateralRequired -= policyDetails[_policyId].claimPayout * policyDetails[_policyId].nbSeatsMax;
            masterPolicy[0].collateralRequired -= policyDetails[_policyId].claimPayout * policyDetails[_policyId].nbSeatsSold;
        }
    }

    function activatePolicy(bytes32 _policyId , uint256 _updateDelayTime, uint _test) public
        onlyAuthorized
        policyExists(_policyId)
    {
        /* Activation triggers the Oracle  (to update the flight info in the future and ask a callback to Oraclize)
        It needs to be activated from the MSC to input the timing for the callback (needs date info)
        (futuredev: instead of calling oraclize twice, use the Otonomi_Oracle database to gather info)*/
        require(policyDetails[_policyId].policyStatus == 0, "Policy already activated");

        // 0- update of MSC meta-variables
        masterPolicy[0].nbPolicies ++;   //we only update active policies.
        masterPolicy[0].MaxCollateralRequired += policyDetails[_policyId].claimPayout * policyDetails[_policyId].nbSeatsMax;

        // 1- resolve flight Info from _policyId
        bytes32 _flightId = policyDetails[_policyId].flightId;
        string memory _fltNum = flightDetails[_flightId].fltNum;
        uint256 _depDte = flightDetails[_flightId].depDte;
        uint256 _expectedArrDte = flightDetails[_flightId].expectedArrDte;

        // 3- activate Policy
        policyDetails[_policyId].claimPayoutBlock = 0;  // force claimPayoutDate to zero (allows payment)
        policyDetails[_policyId].policyStatus = 1;      //Policy is now active!!!

        // 4- trigger external call to Oracle (only if _test = 0)

        if(_updateDelayTime == 0){
            _updateDelayTime = _expectedArrDte + (3*3600);
        } //3h after exp.arrival

        if(_test == 0) {
            OtonomiOracle_Interface(oracleAddress).triggerOracle(_policyId, _fltNum, _depDte, _expectedArrDte, _updateDelayTime, address(this));
        }

        emit LogBytes32("Policy Activated", _policyId);
    }

    /*  Later, the oracle will perform a callback and will trigger "updateFromOracle" function below:
        -> changePolicyStatus: avoids customers to subscribe once the callback is asked.
        -> updateFlightInformation: update flight arrival date in the MSC _flightId
        -> processPayments: loop ont he existing customers addresses and token transfer.
    we proceed to a MANUAL update for tests */

    //ADMIN:  updateFlight INFORMATION (called from ORACLE)
    function updateFromOracle(
        bytes32 _policyId,
        bytes32 _flightId,
        int256 _actualArrDte,
        uint8 _fltStatus
        ) public
    onlyAuthorized
    {
        changePolicyStatus(_policyId, 2); //subscriptions closed, ready to pay.
        uint256 delayBuffer = policyDetails[_policyId].dlyTime;
        updateFlightInformation(_flightId, _actualArrDte, delayBuffer, _fltStatus);
        uint nbCustomers = getNbCustomers(_policyId);

        if (nbCustomers == 0 || flightDetails[_flightId].fltStatus == 1) {
            changePolicyStatus(_policyId, 3);
            emit NoClaim(nbCustomers, _policyId, _flightId, _actualArrDte, flightDetails[_flightId].fltStatus);
            emit LogBytes32("Policy completed", _policyId); //TODO: change to 'expired'
            return;
        }

        if (nbCustomers > 0 && flightDetails[_flightId].fltStatus == 2) {
            // TODO: Need to calculate the actual delay to determine if payment is due
            // flightDetails[_flightId].actualArrDte > (flightDetails[_flightId].expectedArrDte + policy[policytId].dlyTime)
            emit PaymentDue(nbCustomers, _policyId, _flightId, _actualArrDte, flightDetails[_flightId].fltStatus);
        }
    }

    function changePolicyStatus(bytes32 _policyId, uint8 _policyStatus) internal policyExists(_policyId) {
        policyDetails[_policyId].policyStatus = _policyStatus; //0= locked, 1= active for subscription, 2= oracle answered (=payment), 3= payment processed
    }

    function updateFlightInformation(bytes32 _flightId, int256 _actualArrDte, uint256 _delayBuffer, uint8 _fltStatus) 
        internal flightExists(_flightId)  {
    //flight details update:
        flightDetails[_flightId].actualArrDte = _actualArrDte;
        // adjust flight delay status to contract parameters (delay covered)
        if (_fltStatus != 2) {
            flightDetails[_flightId].fltStatus = _fltStatus;
            return;
        }
        // check that delay meets policy requirements
        (, uint8 _policyfltSts) = updateFlightDelay(_actualArrDte, flightDetails[_flightId].expectedArrDte, _delayBuffer);
        flightDetails[_flightId].fltStatus = _policyfltSts;
    }

    function processPayments(bytes32 _policyId) public
        onlyAuthorized
        policyCanProcessPayment(_policyId)
        returns(uint256 _nbClientsPaid, uint256 _nbSeatsPaid, uint256 _amountPaid)
    {
        require(PAYMT > 0, "Payments are disabled");
        // 1- loop on clients who subscribed and transfer of tokens
        uint256 nbCustomers = getNbCustomers(_policyId); //getter: see at the end of the code.
        //TODO: Below block is for early phase testing, remove after payments integration
        if (nbCustomers > 1) {
            emit LogBytes32("Policy requires transfer", _policyId);
            return (0, 0, 0); //total
        }

        for (uint256 i = 0; i < nbCustomers; i++) {
            address _client = ListOfCustomers[_policyId][i];

            _amountPaid += clientsSubscriptions[_client][_policyId].nbSeatsPurchased*policyDetails[_policyId].claimPayout;
            _nbClientsPaid ++;
            _nbSeatsPaid += clientsSubscriptions[_client][_policyId].nbSeatsPurchased;

            tokenTransferClaimPayout(_client, _policyId, 0); //put test = 0 to actually transfer
        }

        // 3- policy status update & event log
        policyDetails[_policyId].claimPayoutBlock = block.timestamp; //update payout time.
        changePolicyStatus(_policyId, 3); //payments tx have been processed (awaiting mining)
        masterPolicy[0].collateralRequired -= _amountPaid; //update of the collateralRequired in the MSC
        masterPolicy[0].nbPolicies --;

        emit LogBytes32("Policy payout has been processed", _policyId);
        return(_nbClientsPaid, _nbSeatsPaid, _amountPaid); //total
    } //end of payments processing

    function tokenTransferClaimPayout(address _client, bytes32 _policyId, uint8 _test) internal clientEligibleToClaim(_client, _policyId) {

        uint256 _clientPayout = clientsSubscriptions[_client][_policyId].nbSeatsPurchased * policyDetails[_policyId].claimPayout;

        clientsSubscriptions[_client][_policyId].claimPaid = _clientPayout;
        //clientsSubscriptions[_client][_policyId].datePaid = block.timestamp; //future use ?
    }


    //CLIENT: Interaction with Policy. entry point is the PolicyID (because you can have 2 flightId for the same PolicyId)

    // 1- Client purchase (see ERC20_FLY token modification):
    // use 3 standard functions to make the MSC a "merchant" towards the token holders
    function _getProductAvail(bytes32 _productId) public view returns (bool availability) {
        //note: the shop needs to make sure that the products are listed correctly.
        return(policyDetails[_productId].policyStatus == 1);
    }

    function _getProductPrice(bytes32 _productId) public view returns (uint price) {
    //note: the shop needs to make sure that the products are listed correctly.
        return(policyDetails[_productId].premium);
    }


    function clientInsuranceSubscribe(
        address _client,
        bytes32 _policyId,
        uint256 seats
    ) public onlyAuthorized policyPurcheasable(_policyId) returns (bool success) {
        require(seats <= 3, "More then 3 seats");

        //do an actual transfer of tokens for payment (if allowed)
        // IERC20(tokenAddress).transferFrom(_client, address(this), policyDetails[_policyId].premium);

        //update ListofCustomers ARRAY

        ListOfCustomers[_policyId].push(_client); //for this _policyId we update the client list. (will be used to PAY them)
        policyDetails[_policyId].nbClients++;
        ListofPoliciesSubscribed[_client].push(_policyId); //for this client we update the list of policies he subscribed to

        // key = customers addresses, bytes32 = policyId, bool = true if policy is ongoing, false if not subscribed or paid/resolved
        //money:
        clientsSubscriptions[_client][_policyId].datePurchased = block.timestamp; //latest date
        clientsSubscriptions[_client][_policyId].claimPaid = 0; //no claim paid yet.
        clientsSubscriptions[_client][_policyId].claimPayout = 0; // to calculate payout

        //flight status & seats:
        clientsSubscriptions[_client][_policyId].nbSeatsPurchased = seats;
        policyDetails[_policyId].nbSeatsSold = policyDetails[_policyId].nbSeatsSold + seats;

        // update collateral required
        masterPolicy[0].collateralRequired += policyDetails[_policyId].claimPayout * seats;

        emit LogPurchasedProduct(_client, policyDetails[_policyId].premium, _policyId);

        return true;
    }

    ///--- PURE ADMIN FUNCTIONS: update of variables, override -----


    //Oraclize update //generates an error
    function update_Oraclize(address _newAddress) public onlyOwner { //payable in real
        removeAuthorized(oracleAddress);
        oracleAddress = _newAddress;
        addAuthorized(_newAddress);
    }

    //Killswitch
    function _killContract(bool _forceKill) public onlyOwner {
        selfdestruct(msg.sender); //kill --> make sure that the TOKEN balances are ZERO
    }

  //Hash Calculation functions
    function createPolicyId(
        string memory _fltNum,
        uint256 _depDte,
        uint _expectedArrDte,
        uint256 _dlyTime,
        uint256 _premium,
        uint _claimPayout,
        uint256 _expiryDte,
        uint256 _nbSeatsMax
    ) public pure returns (bytes32) {

        return keccak256(abi.encodePacked(
            createFlightId(_fltNum, _depDte), _expectedArrDte, _dlyTime, _premium, _claimPayout, _expiryDte, _nbSeatsMax)
        );
    }

    function createFlightId(string memory _fltNum, uint256 _depDte) public pure returns (bytes32){
        return keccak256(abi.encodePacked(_fltNum, _depDte));
    }

  //getter function for array size retrieval
    function getNbCustomers(bytes32 _policyId) public view returns (uint256) {
        return ListOfCustomers[_policyId].length;
    }


} //--- END OF CODE -------------

pragma solidity ^0.5.0;

//Set of common functions to import is MSC and ORACLE.
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Authorizable.sol";

//Common functions, including the method to create flightId and policyId hashes
contract usingOtonomiBasics is Authorizable {
    
    
    //Calculation functions
    function createPolicyId(string memory _fltNum, uint256 _depDte, uint _expectedArrDte, uint256 _dlyTime, uint256 _premium, uint _claimPayout, uint256 _expiryDte, uint256 _nbSeatsMax)
    public pure returns (bytes32 ) {
            return keccak256(abi.encodePacked(createFlightId(_fltNum, _depDte), _expectedArrDte, _dlyTime, _premium, _claimPayout, _expiryDte, _nbSeatsMax));
    }
    function createFlightId(string memory _fltNum, uint256 _depDte)
    public pure returns (bytes32) {
      return keccak256(abi.encodePacked(_fltNum, _depDte));
    }

    function updateFlightDelay(int256 _actualArrDte, uint256 _expectedArrDte)
        internal pure returns(uint256 _flightDelay, uint8 _fltSts) {
        uint256 MIN_DELAY_BUFFER = 900; //15 min is the smallest delay to cover
        if (_actualArrDte < 0) { // flight is cancelled
            _flightDelay = 10800;
            _fltSts = 3;
        }
        else if (uint256(_actualArrDte) > (_expectedArrDte + MIN_DELAY_BUFFER)) {
            _flightDelay = (uint256(_actualArrDte) - _expectedArrDte);
            _fltSts = 2;
        }
        else {
            _flightDelay = 0; 
            _fltSts = 1;
        }
    }
    
    function updateFlightDelay(int256 _actualArrDte, uint256 _expectedArrDte, uint256 delayBuffer)
        internal pure returns(uint256 _flightDelay, uint8 _fltSts) {
        if (_actualArrDte < 0) { // flight is cancelled
            _flightDelay = 10800;
            _fltSts = 3;
        }
        else if (uint256(_actualArrDte) > (_expectedArrDte + delayBuffer)) {
            _flightDelay = (uint256(_actualArrDte) - _expectedArrDte);
            _fltSts = 2;
        }
        else {
            _flightDelay = 0; 
            _fltSts = 1;
        }
    }


    //Token Interactions
    function withdrawTokens(address _tokenAddress, address _recipient)
    public onlyOwner returns (uint256 _withdrawal) {
        _withdrawal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(_recipient, _withdrawal);
    }
    function _checkTokenBalances(address _tokenAddress)
    public view returns(uint256 _tokenBalance) {
        _tokenBalance = IERC20(_tokenAddress).balanceOf(address(this));
    }

    //Killswitch
    function _killContract(bool _forceKill, address _tokenAddress)
    public onlyOwner {
        if(_forceKill == false){require(IERC20(_tokenAddress).balanceOf(address(this)) == 0, "Please withdraw Tokens");} //Require: TOKEN balances = 0
        selfdestruct(msg.sender); //kill
    }

}

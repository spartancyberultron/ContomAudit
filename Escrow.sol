pragma solidity ^0.5.0;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// client payment
// client payaout

contract Escrow is Ownable {
    IERC20 public token;
    
    mapping (bytes32 => mapping(address => uint)) payments;
    mapping (bytes32 => mapping(address => uint)) payouts;
    
    uint public totalPayouts;
    
    event PayoutCompleted(bytes32 policyId, address customer);
    
    constructor(address _token) public payable {
        token = IERC20(_token);
    }
    
    function processInsurancePayment(address client, bytes32 policyId) external onlyOwner {
        require(payments[policyId][client] > 0, "Premium payment does not exists for client.");
        require(payouts[policyId][client] > 0, "No payout exists for client.");
        uint256 amount = payouts[policyId][client];
        require(token.balanceOf(address(this)) >= amount, "Not enough collateral.");
        
        totalPayouts = totalPayouts + amount;
        payouts[policyId][client] = 0;
        
        token.transfer(address(client), amount);
        emit PayoutCompleted(policyId, client);
    }
    
    function addClientPayment(address client, uint amount, bytes32 policyId, uint claimPayouts) external onlyOwner {
        payments[policyId][client] = amount;
        payouts[policyId][client] = claimPayouts;
    }
    
    function withdrawTokens(address _recipient, uint256 _value) public onlyOwner {
        require(token.balanceOf(address(this)) >= _value, "Insufficient funds");
        token.transfer(_recipient, _value);
    }
    
    function withdrawErc20(IERC20 _token) public onlyOwner {
        _token.transfer(msg.sender, _token.balanceOf(address(this)));
    }
    
    function getClientPayment(bytes32 policyId, address client) public view returns(uint256) {
        return payments[policyId][client];
    }
    
    function getClientPayout(bytes32 policyId, address client) public view returns(uint256) {
        return payouts[policyId][client];
    }
    
    function _killContract(bool _forceKill) external onlyOwner {
        if(_forceKill == false) {
            require(token.balanceOf(address(this)) == 0, "Please withdraw Tokens");
            
        } //Require: TOKEN balances = 0
        selfdestruct(msg.sender); //kill
    }
}

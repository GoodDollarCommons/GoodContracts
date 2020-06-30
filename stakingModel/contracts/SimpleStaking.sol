pragma solidity 0.5.4;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "@daostack/arc/contracts/controller/Avatar.sol";
import "../../contracts/dao/schemes/FeelessScheme.sol";
import "../../contracts/identity/Identity.sol";
import "../../contracts/DSMath.sol";
import "./AbstractGoodStaking.sol";

/**
 * @title Staking contract that donates earned interest to the DAO
 * allowing stakers to deposit Tokens
 * or withdraw their stake in Tokens
 * the contracts buy intrest tokens and can transfer the daily interest to the  DAO
 */
contract SimpleStaking is DSMath, Pausable, FeelessScheme, AbstractGoodStaking {
    using SafeMath for uint256;

    ERC20 token;
    ERC20 iToken;

    uint256 public blockInterval;
    uint256 lastUBICollection;
    uint256 public totalStaked = 0;

    //how much of the generated interest is donated, meaning no G$ is expected in compensation, 1 in mil precision.
    //100% for phase0 POC
    uint32 public avgInterestDonatedRatio = 1e6;

    address public fundManager;

    modifier onlyFundManager {
        require(msg.sender == fundManager, "Only FundManager can call this method");
        _;
    }


    constructor(
        address _token,
        address _iToken,
        address _fundManager,
        uint256 _blockInterval,
        Avatar _avatar,
        Identity _identity
    ) public FeelessScheme(_identity, _avatar) {
        token = ERC20(_token);
        iToken = ERC20(_iToken);
        blockInterval = _blockInterval;
        lastUBICollection = block.number.div(blockInterval);
        fundManager = _fundManager;
        addPauser(address(avatar));
    }

    /**
    @dev allow the DAO to change the fund manager contract
    @param _fundManager address of the new contract
    */
    function setFundManager(address _fundManager) public onlyAvatar {
        fundManager = _fundManager;
    }

    /**
     * @dev stake some Token
     * @param amount of Token to stake
     */
    function stake(uint256 amount) external whenNotPaused {
        
        require(amount > 0, "You need to stake a positive token amount");
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "transferFrom failed, make sure you approved token transfer"
        );

        // approve the transfer to defi protocol
        token.approve(address(iToken), amount);
        mint(amount); //mint iToken

        Staker storage staker = stakers[msg.sender];
        staker.stakedToken = staker.stakedToken.add(amount);
        staker.lastStake = block.number;
        totalStaked = totalStaked.add(amount);
        emit Staked(msg.sender, address(token), amount);
    }

    /**
     * @dev withdraw all staked Token
     */
    function withdrawStake() external {
        Staker storage staker = stakers[msg.sender];
        require(staker.stakedToken > 0, "No DAI staked");
        uint256 tokenWithdraw = staker.stakedToken;
        uint256 tokenActual = token.balanceOf(address(this));
        if (tokenActual < tokenWithdraw) {
            tokenWithdraw = tokenActual;
        }
        redeem(tokenWithdraw);
        staker.stakedToken = staker.stakedToken.sub(tokenWithdraw); // update balance before transfer to prevent re-entry
        totalStaked = totalStaked.sub(tokenWithdraw);
        require(token.transfer(msg.sender, tokenWithdraw), "withdraw transfer failed");
        emit StakeWithdraw(msg.sender, address(token), tokenWithdraw, tokenActual);
    }

    function currentTokenWorth() public view returns (uint256) {
        uint256 er = exchangeRate();

        //TODO: why 1e10? cDai is e8 so we should convert it to e28 like exchange rate
        //TODO need to make it generic..because decimals may vary in other defi protocol
        uint256 tokenBalance = rmul(iToken.balanceOf(address(this)) * 1e10, er).div(10);
        return tokenBalance;
    }

    function currentUBIInterest()
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 er = exchangeRate();
        uint256 tokenWorth = currentTokenWorth();
        if (tokenWorth <= totalStaked) {
            return (0, 0, 0);
        }
        uint256 tokenGains = tokenWorth.sub(totalStaked);
        //mul by 1e10 to equalize precision otherwise since exchangerate is very big, dividing by it would result in 0.
        uint256 iTokenGains = rdiv(tokenGains * 1e10, er);
        //get right most bits not covered by precision of cdai which is only 8 decimals while RAY is 27
        uint256 precisionLossITokenRay = iTokenGains % 1e19;
         // lower back to 8 decimals
        iTokenGains = iTokenGains.div(1e19);
        //div by 1e10 to get results in dai precision 1e18
        uint256 precisionLossToken = rmul(precisionLossITokenRay, er).div(1e10);
        return (iTokenGains, tokenGains, precisionLossToken);
    }

    /**
     * @dev collect gained interest by fundmanager
     * @param recipient of cDAI gains
     */
    function collectUBIInterest(address recipient)
        public
        onlyFundManager
        returns (
            uint256,
            uint256,
            uint256,
            uint32
        )
    {
        require(recipient != address(this), "Recipient cannot be the staking contract"); // otherwise fund manager has to wait for the next interval

        require(canCollect(), "Need to wait for the next interval");

        (
            uint256 iTokenGains,
            uint256 tokenGains,
            uint256 precisionLossToken
        ) = currentUBIInterest();
        lastUBICollection = block.number.div(blockInterval);
        if (iTokenGains > 0)
            require(iToken.transfer(recipient, iTokenGains), "collect transfer failed");
        emit InterestCollected(recipient, address(token), iTokenGains, tokenGains, precisionLossToken);
        return (iTokenGains, tokenGains, precisionLossToken, avgInterestDonatedRatio);
    }

    /**
     * @dev can fund manager collect interest
     * @return bool - true if enough time has passed (counted in blocks)
     */
    function canCollect() public view returns (bool) {
        return block.number.div(blockInterval) > lastUBICollection;
    }

    /**
     * @dev making the contract active
     */
    function start() public onlyRegistered {
        addRights();
    }

    /**
     * @dev making the contract inactive
     * NOTICE: this could theoretically result in future interest earned in cdai to remain locked
     * but we dont expect any other stakers but us in SimpleDAIStaking
     */
    function end() public onlyAvatar {
        pause();
        removeRights();
    }
}

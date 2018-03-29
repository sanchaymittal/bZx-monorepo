
pragma solidity ^0.4.19;

import 'zeppelin-solidity/contracts/math/SafeMath.sol';

import '../modifiers/B0xOwnable.sol';

import '../modifiers/EMACollector.sol';
import '../modifiers/GasRefunder.sol';
import '../B0xVault.sol';
import '../shared/B0xTypes.sol';
import '../shared/Debugger.sol';

import '../tokens/EIP20.sol';
import '../interfaces/Oracle_Interface.sol';
import '../interfaces/KyberNetwork_Interface.sol';

/*
// used for getting data from b0x
contract B0xInterface {
    function getLoanOrderParts (
        bytes32 loanOrderHash)
        public
        view
        returns (address[6],uint[9]);

    function getLoanParts (
        bytes32 loanOrderHash,
        address trader)
        public
        view
        returns (address,uint[4],bool);

    function getPositionParts (
        bytes32 loanOrderHash,
        address trader)
        public
        view
        returns (address,uint[4],bool);
}
*/

contract B0xOracle is Oracle_Interface, EMACollector, GasRefunder, B0xTypes, Debugger, B0xOwnable {
    using SafeMath for uint256;

    address constant KYBER_ETH_TOKEN_ADDRESS = 0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;

    // Percentage of interest retained as fee
    // This will always be between 0 and 100
    uint public interestFeePercent = 10;

    // Percentage of liquidation level that will trigger a liquidation of positions
    // This can never be less than 100
    uint public liquidationThresholdPercent = 110;

    // Percentage of gas refund paid to non-bounty hunters
    uint public gasRewardPercent = 90;

    // Percentage of gas refund paid to bounty hunters after successfully liquidating a position
    uint public bountyRewardPercent = 110;

    address public VAULT_CONTRACT;
    address public KYBER_CONTRACT;

    mapping (bytes32 => GasData[]) public gasRefunds; // // mapping of loanOrderHash to array of GasData

    // Only the owner can directly deposit ether
    function() public payable onlyOwner {}

    function B0xOracle(
        address _vault_contract,
        address _kyber_contract) 
        public
        payable
    {
        VAULT_CONTRACT = _vault_contract;
        KYBER_CONTRACT = _kyber_contract;

        // settings for EMACollector
        emaValue = 20 * 10**9 wei; // set an initial price average for gas (20 gwei)
        emaPeriods = 10; // set periods to use for EMA calculation
    }

    // standard functions

    function didTakeOrder(
        bytes32 loanOrderHash,
        address taker,
        uint gasUsed)
        public
        onlyB0x
        updatesEMA(tx.gasprice)
        returns (bool)
    {
        gasRefunds[loanOrderHash].push(GasData({
            payer: taker,
            gasUsed: gasUsed.sub(msg.gas),
            isPaid: false
        }));

        return true;
    }

    function didTradePosition(
        bytes32 /* loanOrderHash */,
        address /* trader */,
        address /* tradeTokenAddress */,
        uint /* tradeTokenAmount */,
        uint /* gasUsed */)
        public
        onlyB0x
        updatesEMA(tx.gasprice)
        returns (bool)
    {
        return true;
    }

    function didPayInterest(
        bytes32 /* loanOrderHash */,
        address /* trader */,
        address lender,
        address interestTokenAddress,
        uint amountOwed,
        uint /* gasUsed */)
        public
        onlyB0x
        updatesEMA(tx.gasprice)
        returns (bool)
    {
        // interestFeePercent is only editable by owner
        uint interestFee = amountOwed.mul(interestFeePercent).div(100);

        // Transfers the interest to the lender, less the interest fee.
        // The fee is retained by the oracle.
        if (!_transferToken(
            interestTokenAddress,
            lender,
            amountOwed.sub(interestFee))) {
            revert();
        }

        return true;
    }

    function didDepositCollateral(
        bytes32 /* loanOrderHash */,
        address /* borrower */,
        uint /* gasUsed */)
        public
        onlyB0x
        updatesEMA(tx.gasprice)
        returns (bool)
    {
        return true;
    }

    function didChangeCollateral(
        bytes32 /* loanOrderHash */,
        address /* borrower */,
        uint /* gasUsed */)
        public
        onlyB0x
        updatesEMA(tx.gasprice)
        returns (bool)
    {
        return true;
    }

    function didCloseLoan(
        bytes32 loanOrderHash,
        address closer,
        bool isLiquidation,
        uint gasUsed)
        public
        onlyB0x
        //refundsGas(taker, emaValue, gasUsed, 0) // refunds based on collected gas price EMA
        updatesEMA(tx.gasprice)
        returns (bool)
    {
        // sends gas and bounty reward to bounty hunter
        if (isLiquidation) {
            calculateAndSendRefund(
                closer,
                gasUsed,
                emaValue,
                bountyRewardPercent);
        }
        
        // sends gas refunds owed from earlier transactions
        for (uint i=0; i < gasRefunds[loanOrderHash].length; i++) {
            GasData storage gasData = gasRefunds[loanOrderHash][i];
            if (!gasData.isPaid) {
                if (sendRefund(
                    gasData.payer,
                    gasData.gasUsed,
                    emaValue,
                    gasRewardPercent))               
                        gasData.isPaid = true;
            }
        }
        
        return true;
    }

    function doTrade(
        address sourceTokenAddress, // typically tradeToken
        address destTokenAddress,   // typically loanToken
        uint sourceTokenAmount)
        public
        onlyB0x
        returns (uint destTokenAmount)
    {
        destTokenAmount = _doTrade(
            sourceTokenAddress,
            destTokenAddress,
            sourceTokenAmount,
            MAX_UINT); // no limit on the dest amount
    }

    function verifyAndDoTrade(
        address sourceTokenAddress, // typically tradeToken
        address destTokenAddress,   // typically loanToken
        address collateralTokenAddress,
        uint sourceTokenAmount,
        uint collateralTokenAmount,
        uint maintenanceMarginAmount)
        public
        onlyB0x
        returns (uint destTokenAmount)
    {
        if (!shouldLiquidate(
            0x0,
            0x0,
            sourceTokenAddress,
            collateralTokenAddress,
            sourceTokenAmount,
            collateralTokenAmount,
            maintenanceMarginAmount)) {
            return 0;
        }
        
        destTokenAmount = _doTrade(
            sourceTokenAddress,
            destTokenAddress,
            sourceTokenAmount,
            MAX_UINT); // no limit on the dest amount
    }

    function doTradeofCollateral(
        address collateralTokenAddress,
        address loanTokenAddress,
        uint collateralTokenAmountUsable,
        uint loanTokenAmountNeeded)
        public
        onlyB0x
        returns (uint loanTokenAmountCovered, uint collateralTokenAmountUsed)
    {
        uint collateralTokenBalance = EIP20(collateralTokenAddress).balanceOf.gas(4999)(this); // Changes to state require at least 5000 gas
        if (collateralTokenBalance < collateralTokenAmountUsable) {
            revert();
        }
        
        loanTokenAmountCovered = _doTrade(
            collateralTokenAddress,
            loanTokenAddress,
            collateralTokenAmountUsable,
            loanTokenAmountNeeded);

        collateralTokenAmountUsed = collateralTokenBalance.sub(EIP20(collateralTokenAddress).balanceOf.gas(4999)(this)); // Changes to state require at least 5000 gas

        // send unused collateral token back to the vault
        if (!_transferToken(
            collateralTokenAddress,
            VAULT_CONTRACT,
            collateralTokenAmountUsable.sub(collateralTokenAmountUsed))) {
            revert();
        }
    }

    /*
    * Public View functions
    */

    function shouldLiquidate(
        bytes32 /* loanOrderHash */,
        address /* trader */,
        address positionTokenAddress,
        address collateralTokenAddress,
        uint positionTokenAmount,
        uint collateralTokenAmount,
        uint maintenanceMarginAmount)
        public
        view
        returns (bool)
    {
        return (getCurrentMargin(
                positionTokenAddress,
                collateralTokenAddress,
                positionTokenAmount,
                collateralTokenAmount).div(maintenanceMarginAmount) <= (liquidationThresholdPercent));
    } 

    function isTradeSupported(
        address sourceTokenAddress,
        address destTokenAddress)
        public
        view 
        returns (bool)
    {
        return (getTradeRate(sourceTokenAddress, destTokenAddress) > 0);
    }

    function getTradeRate(
        address sourceTokenAddress,
        address destTokenAddress)
        public
        view 
        returns (uint rate)
    {   
        if (KYBER_CONTRACT == address(0)) {
            rate = (uint(block.blockhash(block.number-1)) % 100 + 1).mul(10**18);
        } else {
            var (, sourceToEther) = KyberNetwork_Interface(KYBER_CONTRACT).findBestRate(
                sourceTokenAddress, 
                KYBER_ETH_TOKEN_ADDRESS,
                0
            );
            var (, etherToDest) = KyberNetwork_Interface(KYBER_CONTRACT).findBestRate(
                KYBER_ETH_TOKEN_ADDRESS,
                destTokenAddress, 
                0
            );
            
            rate = sourceToEther.mul(etherToDest).div(10**18);
        }
    }

    function getCurrentMargin(
        address positionTokenAddress,
        address collateralTokenAddress,
        uint positionTokenAmount,
        uint collateralTokenAmount)
        public
        view
        returns (uint currentMarginAmount)
    {
        uint positionToCollateralRate = getTradeRate(
            positionTokenAddress,
            collateralTokenAddress
        );
        if (positionToCollateralRate == 0) {
            return 0;
        }

        currentMarginAmount = collateralTokenAmount
                        .div(positionTokenAmount)
                        .div(positionToCollateralRate)
                        .mul(10**20);
    }

    /*
    * Internal functions
    */

    function _doTrade(
        address sourceTokenAddress,
        address destTokenAddress,
        uint sourceTokenAmount,
        uint maxDestTokenAmount)
        internal
        returns (uint destTokenAmount)
    {
        if (KYBER_CONTRACT == address(0)) {
            uint tradeRate = getTradeRate(sourceTokenAddress, destTokenAddress);
            destTokenAmount = sourceTokenAmount.mul(tradeRate).div(10**18);
            if (destTokenAmount > maxDestTokenAmount) {
                destTokenAmount = maxDestTokenAmount;
            }
            if (!_transferToken(
                destTokenAddress,
                VAULT_CONTRACT,
                destTokenAmount)) {
                revert();
            }
        } else {
            uint destEtherAmount = KyberNetwork_Interface(KYBER_CONTRACT).trade(
                sourceTokenAddress,
                sourceTokenAmount,
                KYBER_ETH_TOKEN_ADDRESS,
                this, // B0xOracle receives the Ether proceeds
                maxDestTokenAmount,
                0, // no min coversation rate
                this
            );

            destTokenAmount = KyberNetwork_Interface(KYBER_CONTRACT).trade
                .value(destEtherAmount)( // send Ether along 
                KYBER_ETH_TOKEN_ADDRESS,
                destEtherAmount,
                destTokenAddress,
                VAULT_CONTRACT, // b0xVault recieves the destToken
                maxDestTokenAmount,
                0, // no min coversation rate
                this
            );
        }
    }

    function _transferToken(
        address tokenAddress,
        address to,
        uint value)
        internal
        returns (bool)
    {
        if (!EIP20(tokenAddress).transfer(to, value))
            revert();

        return true;
    }

    /*
    * Internal View functions
    */

    /*function getLoanOrder (
        bytes32 loanOrderHash)
        internal
        view
        returns (LoanOrder)
    {
        var (addrs, uints) = B0xInterface(b0xContractAddress).getLoanOrderParts(loanOrderHash);

        return buildLoanOrderStruct(loanOrderHash, addrs, uints);
    }

    function getLoan (
        bytes32 loanOrderHash,
        address trader)
        internal
        view
        returns (Loan)
    {
        var (lender, uints, active) = B0xInterface(b0xContractAddress).getLoanParts(loanOrderHash, trader);

        return buildLoanStruct(lender, uints, active);
    }

    function getPosition (
        bytes32 loanOrderHash,
        address trader)
        internal
        view
        returns (Position)
    {
        var (tradeTokenAddress, uints, active) = B0xInterface(b0xContractAddress).getPositionParts(loanOrderHash, trader);

        return buildTradeStruct(tradeTokenAddress, uints, active);
    }*/

    function getDecimals(EIP20 token) 
        internal
        view 
        returns(uint)
    {
        return token.decimals();
    }


    /*
    * Owner functions
    */

    function setInterestFeePercent(
        uint newRate) 
        public
        onlyOwner
    {
        require(newRate != interestFeePercent && newRate >= 0 && newRate <= 100);
        interestFeePercent = newRate;
    }

    function setLiquidationThresholdPercent(
        uint newValue) 
        public
        onlyOwner
    {
        require(newValue != liquidationThresholdPercent && liquidationThresholdPercent >= 100);
        liquidationThresholdPercent = newValue;
    }

    function setGasRewardPercent(
        uint newValue) 
        public
        onlyOwner
    {
        require(newValue != gasRewardPercent);
        gasRewardPercent = newValue;
    }

    function setBountyRewardPercent(
        uint newValue) 
        public
        onlyOwner
    {
        require(newValue != bountyRewardPercent);
        bountyRewardPercent = newValue;
    }

    function setVaultContractAddress(
        address newAddress) 
        public
        onlyOwner
    {
        require(newAddress != VAULT_CONTRACT && newAddress != address(0));
        VAULT_CONTRACT = newAddress;
    }

    function setKyberContractAddress(
        address newAddress) 
        public
        onlyOwner
    {
        require(newAddress != KYBER_CONTRACT && newAddress != address(0));
        KYBER_CONTRACT = newAddress;
    }

    function setEMAPeriods (
        uint _newEMAPeriods)
        public
        onlyOwner {
        require(_newEMAPeriods > 1 && _newEMAPeriods != emaPeriods);
        emaPeriods = _newEMAPeriods;
    }
}

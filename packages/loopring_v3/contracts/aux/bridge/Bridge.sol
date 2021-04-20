// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../../core/iface/IExchangeV3.sol";
import "../../core/impl/libtransactions/TransferTransaction.sol";
import "../../core/impl/libtransactions/WithdrawTransaction.sol";
import "../../lib/AddressUtil.sol";
import "../../lib/ERC20SafeTransfer.sol";
import "../../lib/ERC20.sol";
import "../../lib/MathUint.sol";
import "../../lib/MathUint96.sol";
import "../../lib/TransferUtil.sol";
import "./BatchDepositor.sol";
import "./IBridge.sol";

/// @title  Bridge implementation
/// @author Brecht Devos - <brecht@loopring.org>
contract Bridge is IBridge, BatchDepositor
{
    using AddressUtil       for address;
    using AddressUtil       for address payable;
    using BytesUtil         for bytes;
    using ERC20SafeTransfer for address;
    using MathUint          for uint;
    using MathUint96        for uint96;
    using TransferUtil      for address;

    event ConnectorCalled  (address connector, bool success, bytes reason);
    event ConnectorTrusted (address connector, bool trusted);

    struct DepositBatch
    {
        uint     batchID;
        uint96[] amounts;
    }

    struct ConnectorCall
    {
        address                     connector;
        uint                        gasLimit;
        ConnectorTxGroup[] groups;
    }

    struct Context
    {
        TokenData[] tokens;
        uint        tokensOffset;
        uint        txsDataPtr;
        uint        txsDataPtrStart;
    }

    struct CallTransfer
    {
        uint fromAccountID;
        uint tokenID;
        uint amount;
        uint feeTokenID;
        uint fee;
        uint storageID;
        uint packedData;
    }

    bytes32 constant public CONNECTOR_TRANSACTION_TYPEHASH = keccak256(
        "ConnectorTx(uint16 tokenID,uint96 amount,uint16 feeTokenID,uint96 maxFee,uint32 validUntil,uint32 storageID,uint32 minGas,address connector,bytes groupData,bytes userData)"
    );

    uint               public constant  MAX_FEE_BIPS              = 25;     // 0.25%
    uint               public constant  GAS_LIMIT_CHECK_GAS_LIMIT = 10000;

    bytes32            public immutable DOMAIN_SEPARATOR;

    mapping (address => bool) public trustedConnectors;

    constructor(
        IExchangeV3 _exchange,
        uint32      _accountID
        )
        BatchDepositor(_exchange, _accountID)
    {
        DOMAIN_SEPARATOR = EIP712.hash(EIP712.Domain("Bridge", "1.0", address(this)));
    }

    function onReceiveTransactions(
        bytes calldata txsData,
        bytes calldata /*callbackData*/
        )
        external
        override
        onlyFromExchangeOwner
    {
        // Get the offset to txsData in the calldata
        uint txsDataPtr = 0;
        assembly {
            txsDataPtr := sub(add(txsData.offset, txsDataPtr), 32)
        }
        Context memory ctx = Context({
            tokens: new TokenData[](0),
            tokensOffset: 0,
            txsDataPtr: txsDataPtr,
            txsDataPtrStart: txsDataPtr
        });

        _processTransactions(ctx);

        // Make sure we have consumed exactly the expected number of transactions
        require(txsData.length == ctx.txsDataPtr - ctx.txsDataPtrStart, "INVALID_NUM_TXS");
    }

    function trustConnector(
        address connector,
        bool    trusted
        )
        external
        onlyFromExchangeOwner
    {
        trustedConnectors[connector] = trusted;
        emit ConnectorTrusted(connector, trusted);
    }

    receive() external payable {}

    // --- Internal functions ---

    function _processTransactions(Context memory ctx)
        internal
    {
        // abi.decode(callbackData, (BridgeOperation))
        // Get the calldata structs directly from the encoded calldata bytes data
        DepositBatch[]  calldata depositBatches;
        ConnectorCall[] calldata calls;
        TokenData[]     calldata tokens;
        uint tokensOffset;

        assembly {
            let offsetToCallbackData := add(68, calldataload(36))
            // depositBatches
            depositBatches.offset := add(add(offsetToCallbackData, 32), calldataload(offsetToCallbackData))
            depositBatches.length := calldataload(sub(depositBatches.offset, 32))

            // calls
            calls.offset := add(add(offsetToCallbackData, 32), calldataload(add(offsetToCallbackData, 32)))
            calls.length := calldataload(sub(calls.offset, 32))

            // tokens
            tokens.offset := add(add(offsetToCallbackData, 32), calldataload(add(offsetToCallbackData, 64)))
            tokens.length := calldataload(sub(tokens.offset, 32))
            tokensOffset := sub(tokens.offset, 32)
        }

        ctx.tokensOffset = tokensOffset;
        ctx.tokens = tokens;

        _processDepositBatches(ctx, depositBatches);
        _processConnectorCalls(ctx, calls);
    }

    function _processDepositBatches(
        Context        memory   ctx,
        DepositBatch[] calldata batches
        )
        internal
    {
        for (uint i = 0; i < batches.length; i++) {
            _processDepositBatch(ctx, batches[i]);
        }
    }

    function _processDepositBatch(
        Context       memory   ctx,
        DepositBatch calldata batch
        )
        internal
    {
        uint96[] memory amounts = batch.amounts;

        // Verify transfers
        bytes memory transfersData = new bytes(amounts.length * 34);
        assembly {
            transfersData := add(transfersData, 32)
        }

        for (uint i = 0; i < amounts.length; i++) {
            uint targetAmount = amounts[i];

            (uint packedData, address to, ) = readTransfer(ctx);
            uint tokenID      = (packedData >> 88) & 0xffff;
            uint amount       = (packedData >> 64) & 0xffffff;
            uint fee          = (packedData >> 32) & 0xffff;
            // Decode floats
            amount = (amount & 524287) * (10 ** (amount >> 19));
            fee = (fee & 2047) * (10 ** (fee >> 11));

            // Verify the transaction data
            require(
                // txType == ExchangeData.TransactionType.TRANSFER &&
                // transfer.type == 1 &&
                // transfer.fromAccountID == ctx.accountID &&
                // transfer.toAccountID == UNKNOWN  &&
                packedData & 0xffffffffffff0000000000000000000000000000000000 ==
                (uint(ExchangeData.TransactionType.TRANSFER) << 176) | (1 << 168) | (uint(accountID) << 136) &&
                /*feeTokenID*/(packedData >> 48) & 0xffff == tokenID &&
                fee <= (amount * MAX_FEE_BIPS / 10000) &&
                (100000 - 8) * targetAmount <= 100000 * amount && amount <= targetAmount,
                "INVALID_BRIDGE_TRANSFER_TX_DATA"
            );

            // Pack the transfer data to compare against batch deposit hash
            assembly {
                mstore(add(transfersData, 2), tokenID)
                mstore(    transfersData    , or(shl(96, to), targetAmount))
                transfersData := add(transfersData, 34)
            }
        }

        // Get the original transfers ptr back
        assembly {
            transfersData := sub(transfersData, add(32, mul(34, mload(amounts))))
        }
        // Check if these transfers can be processed
        bytes32 hash = _hashTransfers(transfersData);
        require(!_arePendingDepositsTooOld(batch.batchID, hash), "BATCH_DEPOSITS_TOO_OLD");

        // Mark transfers as completed
        delete pendingDeposits[batch.batchID][hash];
    }

    function _processConnectorCalls(
        Context          memory   ctx,
        ConnectorCall[]  calldata calls
        )
        internal
    {
        // Total amounts transferred to the bridge
        uint[] memory totalAmounts = new uint[](ctx.tokens.length);

        // All resulting deposits from all connector calls
        IBatchDepositor.Deposit[][] memory depositsList = new IBatchDepositor.Deposit[][](calls.length);

        // Verify and execute bridge calls
        for (uint i = 0; i < calls.length; i++) {
            ConnectorCall calldata call = calls[i];

            // Verify the transactions
            _processConnectorCall(ctx, call, totalAmounts);

            // Call the connector
            depositsList[i] = _call(ctx, call, i, calls);
        }

        // Verify withdrawals
        _processWithdrawals(ctx, totalAmounts);

        // Do all resulting transfers back from the bridge to the users
        _batchDeposit(address(this), depositsList);
    }

    function _processConnectorCall(
        Context          memory   ctx,
        ConnectorCall    calldata call,
        uint[]           memory   totalAmounts
        )
        internal
        view
    {
        CallTransfer memory transfer;
        uint totalMinGas = 0;
        for (uint i = 0; i < call.groups.length; i++) {
            ConnectorTxGroup calldata group = call.groups[i];
            for (uint j = 0; j < group.transactions.length; j++) {
                ConnectorTx calldata bridgeTx = group.transactions[j];

                // packedData: txType (1) | type (1) | fromAccountID (4) | toAccountID (4) | tokenID (2) | amount (3) | feeTokenID (2) | fee (2) | storageID (4)
                (uint packedData, , ) = readTransfer(ctx);
                transfer.fromAccountID = (packedData >> 136) & 0xffffffff;
                transfer.tokenID       = (packedData >>  88) & 0xffff;
                transfer.amount        = (packedData >>  64) & 0xffffff;
                transfer.feeTokenID    = (packedData >>  48) & 0xffff;
                transfer.fee           = (packedData >>  32) & 0xffff;
                transfer.storageID     = (packedData       ) & 0xffffffff;

                transfer.amount = (transfer.amount & 524287) * (10 ** (transfer.amount >> 19));
                transfer.fee = (transfer.fee & 2047) * (10 ** (transfer.fee >> 11));

                // Verify that the transaction was approved with an L2 signature
                bytes32 txHash = _hashTx(
                    transfer,
                    bridgeTx.maxFee,
                    bridgeTx.validUntil,
                    bridgeTx.minGas,
                    call.connector,
                    group.groupData,
                    bridgeTx.userData
                );
                verifySignatureL2(ctx, bridgeTx.owner, transfer.fromAccountID, txHash);

                // Find the token in the tokens list
                uint k = 0;
                while (k < ctx.tokens.length && transfer.tokenID != ctx.tokens[k].tokenID) {
                    k++;
                }
                require(k < ctx.tokens.length, "INVALID_INPUT_TOKENS");
                totalAmounts[k] += transfer.amount;

                // Verify the transaction data
                require(
                    // txType == ExchangeData.TransactionType.TRANSFER &&
                    // transfer.type == 1 &&
                    // transfer.fromAccountID == UNKNOWN &&
                    // transfer.toAccountID == ctx.accountID &&
                    packedData & 0xffff00000000ffffffff00000000000000000000000000 ==
                    (uint(ExchangeData.TransactionType.TRANSFER) << 176) | (1 << 168) | (uint(accountID) << 104) &&
                    transfer.fee <= bridgeTx.maxFee &&
                    bridgeTx.validUntil == 0 || block.timestamp < bridgeTx.validUntil &&
                    bridgeTx.token == ctx.tokens[k].token &&
                    bridgeTx.amount == transfer.amount,
                    "INVALID_BRIDGE_CALL_TRANSFER"
                );

                totalMinGas = totalMinGas.add(bridgeTx.minGas);
            }
        }

        // Make sure the gas passed to the connector is at least the sum of all call gas min amounts.
        // So calls basically "buy" a part of the total gas needed to do the batched call,
        // while IBridgeConnector.getMinGasLimit() makes sure the total gas limit makes sense for the
        // amount of work submitted.
        require(call.gasLimit >= totalMinGas, "INVALID_TOTAL_MIN_GAS");
    }

    function _processWithdrawals(
        Context memory ctx,
        uint[]  memory totalAmounts
        )
        internal
    {
        // Verify the withdrawals
        for (uint i = 0; i < ctx.tokens.length; i++) {
            TokenData memory token = ctx.tokens[i];
            // Verify token data
            require(
                _getTokenID(token.token) == token.tokenID &&
                token.amount == totalAmounts[i],
                "INVALID_TOKEN_DATA"
            );

            bytes20 onchainDataHash = WithdrawTransaction.hashOnchainData(
                0,                  // Withdrawal needs to succeed no matter the gas coast
                address(this),      // Withdraw to this contract first
                new bytes(0)
            );

            // Verify withdrawal data
            // Start by reading the first 2 bytes into header
            uint txsDataPtr = ctx.txsDataPtr + 2;
            // header: txType (1) | type (1)
            uint header;
            // packedData: tokenID (2) | amount (12) | feeTokenID (2) | fee (2)
            uint packedData;
            bytes20 dataHash;
            assembly {
                header     := calldataload(    txsDataPtr     )
                packedData := calldataload(add(txsDataPtr, 42))
                dataHash   := and(calldataload(add(txsDataPtr, 78)), 0xffffffffffffffffffffffffffffffffffffffff000000000000000000000000)
            }
            require(
                // txType == ExchangeData.TransactionType.WITHDRAWAL &&
                // withdrawal.type == 1 &&
                header & 0xffff == (uint(ExchangeData.TransactionType.WITHDRAWAL) << 8) | 1 &&
                // withdrawal.tokenID == token.tokenID &&
                // withdrawal.amount == token.amount &&
                // withdrawal.fee == 0,
                packedData & 0xffffffffffffffffffffffffffff0000ffff == (uint(token.tokenID) << 128) | (token.amount << 32) &&
                onchainDataHash == dataHash,
                "INVALID_BRIDGE_WITHDRAWAL_TX_DATA"
            );

            ctx.txsDataPtr += ExchangeData.TX_DATA_AVAILABILITY_SIZE;
        }
    }

    function _call(
        Context          memory   ctx,
        ConnectorCall    calldata call,
        uint                      n,
        ConnectorCall[]  calldata calls
        )
        internal
        returns (IBatchDepositor.Deposit[] memory deposits)
    {
        require(call.connector != address(this), "INVALID_CONNECTOR");
        require(trustedConnectors[call.connector], "ONLY_TRUSTED_CONNECTORS_SUPPORTED");

        // Check if the minimum amount of gas required is achieved
        bytes memory txData = _getConnectorCallData(ctx, IBridgeConnector.getMinGasLimit.selector, calls, n);
        (bool success, bytes memory returnData) = call.connector.fastCall(GAS_LIMIT_CHECK_GAS_LIMIT, 0, txData);
        if (success) {
            require(call.gasLimit >= abi.decode(returnData, (uint)), "GAS_LIMIT_TOO_LOW");
        } else {
            // If the call failed for some reason just continue.
        }

        // Execute the logic using a delegate so no extra deposits are needed
        txData = _getConnectorCallData(ctx,IBridgeConnector.processProcessorTransactions.selector, calls, n);
        (success, returnData) = call.connector.fastDelegatecall(call.gasLimit, txData);

        if (success) {
            emit ConnectorCalled(call.connector, true, "");
            deposits = abi.decode(returnData, (IBatchDepositor.Deposit[]));
        } else {
            // If the call failed return funds to all users
            uint totalNumCalls = 0;
            for (uint i = 0; i < call.groups.length; i++) {
                totalNumCalls += call.groups[i].transactions.length;
            }
            deposits = new IBatchDepositor.Deposit[](totalNumCalls);
            uint txIdx = 0;
            for (uint i = 0; i < call.groups.length; i++) {
                ConnectorTxGroup memory group = call.groups[i];
                for (uint j = 0; j < group.transactions.length; j++) {
                    ConnectorTx memory bridgeTx = group.transactions[j];
                    deposits[txIdx++] = IBatchDepositor.Deposit({
                        owner:  bridgeTx.owner,
                        token:  bridgeTx.token,
                        amount: bridgeTx.amount
                    });
                }
            }
            assert(txIdx == totalNumCalls);
            emit ConnectorCalled(call.connector, false, returnData);
        }
    }

    function _hashTx(
        CallTransfer memory transfer,
        uint                maxFee,
        uint                validUntil,
        uint                minGas,
        address             connector,
        bytes        memory groupData,
        bytes        memory userData
        )
        internal
        view
        returns (bytes32 h)
    {
        bytes32 _DOMAIN_SEPARATOR = DOMAIN_SEPARATOR;
        uint tokenID = transfer.tokenID;
        uint amount = transfer.amount;
        uint feeTokenID = transfer.feeTokenID;
        uint storageID = transfer.storageID;

        /*return EIP712.hashPacked(
            _DOMAIN_SEPARATOR,
            keccak256(
                abi.encode(
                    CONNECTOR_TRANSACTION_TYPEHASH,
                    tokenID,
                    amount,
                    feeTokenID,
                    storageID,
                    minGas,
                    connector,
                    keccak256(groupData),
                    keccak256(userData)
                )
            )
        );*/
        bytes32 typeHash = CONNECTOR_TRANSACTION_TYPEHASH;
        assembly {
            let data := mload(0x40)
            mstore(    data      , typeHash)
            mstore(add(data,  32), tokenID)
            mstore(add(data,  64), amount)
            mstore(add(data,  96), feeTokenID)
            mstore(add(data, 128), maxFee)
            mstore(add(data, 160), validUntil)
            mstore(add(data, 192), storageID)
            mstore(add(data, 224), minGas)
            mstore(add(data, 256), connector)
            mstore(add(data, 288), keccak256(add(groupData, 32), mload(groupData)))
            mstore(add(data, 320), keccak256(add(userData , 32), mload(userData)))
            let p := keccak256(data, 352)
            mstore(data, "\x19\x01")
            mstore(add(data,  2), _DOMAIN_SEPARATOR)
            mstore(add(data, 34), p)
            h := keccak256(data, 66)
        }
    }

    function _getConnectorCallData(
        Context memory            ctx,
        bytes4                    selector,
        ConnectorCall[]  calldata calls,
        uint                      n
        )
        internal
        pure
        returns (bytes memory)
    {
        // Position in the calldata to start copying
        uint offsetToGroups;
        ConnectorTxGroup[] calldata groups = calls[n].groups;
        assembly {
            offsetToGroups := sub(groups.offset, 32)
        }

        // Amount of bytes that need to be copied.
        // Found by either using the offset to the next connector call or (for the last call)
        // using the offset of the data after all calls (which is the tokens array).
        uint txDataSize = 0;
        if (n + 1 < calls.length) {
            uint offsetToCall;
            uint offsetToNextCall;
            assembly {
                offsetToCall := calldataload(add(calls.offset, mul(add(n, 0), 32)))
                offsetToNextCall := calldataload(add(calls.offset, mul(add(n, 1), 32)))
            }
            txDataSize = offsetToNextCall.sub(offsetToCall);
        } else {
            txDataSize = ctx.tokensOffset.sub(offsetToGroups);
        }

        // Create the calldata for the call
        bytes memory txData = new bytes(4 + 32 + txDataSize);
        assembly {
            mstore(add(txData, 32), selector)
            mstore(add(txData, 36), 0x20)
            calldatacopy(add(txData, 68), offsetToGroups, txDataSize)
        }

        return txData;
    }

    function readTransfer(Context memory ctx)
        internal
        pure
        returns (uint packedData, address to, address from)
    {
        // TransferTransaction.readTx(txsData, ctx.txIdx++ * ExchangeData.TX_DATA_AVAILABILITY_SIZE, transfer);

        // Start by reading the first 23 bytes into packedData
        uint txsDataPtr = ctx.txsDataPtr + 23;
        // packedData: txType (1) | type (1) | fromAccountID (4) | toAccountID (4) | tokenID (2) | amount (3) | feeTokenID (2) | fee (2) | storageID (4)
        assembly {
            packedData := calldataload(txsDataPtr)
            to := and(calldataload(add(txsDataPtr, 20)), 0xffffffffffffffffffffffffffffffffffffffff)
            from := and(calldataload(add(txsDataPtr, 40)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        ctx.txsDataPtr += ExchangeData.TX_DATA_AVAILABILITY_SIZE;
    }

    function verifySignatureL2(
        Context memory ctx,
        address        owner,
        uint           accountID,
        bytes32        txHash
        )
        internal
        pure
    {
        /*
        // Read the signature verification transaction
        SignatureVerificationTransaction.SignatureVerification memory verification;
        SignatureVerificationTransaction.readTx(txsData, ctx.txIdx++ * ExchangeData.TX_DATA_AVAILABILITY_SIZE, verification);

        // Verify that the hash was signed on L2
        require(
            verification.owner == owner &&
            verification.accountID == ctx.accountID &&
            verification.data == uint(txHash) >> 3,
            "INVALID_OFFCHAIN_L2_APPROVAL"
        );
        */

        // Read the signature verification transaction
        // Start by reading the first 25 bytes into packedDate
        uint txsDataPtr = ctx.txsDataPtr + 25;
        // packedData: txType (1) | owner (20) | accountID (4)
        uint packedData;
        uint data;
        assembly {
            packedData := calldataload(txsDataPtr)
            data := calldataload(add(txsDataPtr, 32))
        }

        // Verify that the hash was signed on L2
        require(
            packedData & 0xffffffffffffffffffffffffffffffffffffffffffffffffff ==
            (uint(ExchangeData.TransactionType.SIGNATURE_VERIFICATION) << 192) | ((uint(owner) & 0x00ffffffffffffffffffffffffffffffffffffffff) << 32) | accountID &&
            data == uint(txHash) >> 3,
            "INVALID_OFFCHAIN_L2_APPROVAL"
        );

        ctx.txsDataPtr += ExchangeData.TX_DATA_AVAILABILITY_SIZE;
    }
}

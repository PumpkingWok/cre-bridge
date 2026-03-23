// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract Bridge is ReceiverTemplate {
    uint256 public constant CROSS_CHAIN_DELAY = 10 minutes;
    uint256 public immutable chainId;

    struct SrcChainIntent {
        address tokenSrcChain;
        uint256 amountSrcChain;
        uint256 deadline;
        address creator;
    }

    struct DstChainIntent {
        address tokenDstChain;
        uint256 amountDstChain;
        uint256 srcChainId;
        uint256 srcChainIntentId;
        uint256 deadline;
        address receiver;
    }

    mapping(uint256 => SrcChainIntent) public srcChainIntents;
    // srcChainId => srcChainIntentId => DstChainIntent
    mapping(uint256 => mapping(uint256 => DstChainIntent)) public dstChainIntents;
    
    uint256 public intentId;
    
    error IntentExpired();
    error IntentNotExpired();
    error OnlyCreator();
    error WrongDeadline();
    error WrongReport();
    error ZeroAmount();

    event IntentCreated(address, uint256, uint256, uint256, uint256, address, uint256);

    event BridgeFinalized(uint256, uint256, address);

    constructor(uint256 chainId_, address forwarderAddress_) ReceiverTemplate(forwarderAddress_) {
        chainId = chainId_;
    }

    // 1) Action made by user
    // it create an intent even for dstChainId not supported, workflow won't process it (save fees on removing the intent automatically)
    function createIntent(
        address tokenSrcChain,
        address tokenDstChain,
        uint256 amountSrcChain,
        uint256 amountDstChain,
        uint256 dstChainId,
        uint256 deadline,
        address receiver
    ) external {
        if (block.timestamp + 10 minutes > deadline) revert WrongDeadline();
        if (amountSrcChain == 0 || amountDstChain == 0) revert ZeroAmount();
        if (receiver == address(0)) receiver = msg.sender;

        // transfer token here
        IERC20(tokenSrcChain).transferFrom(msg.sender, address(this), amountSrcChain);

        SrcChainIntent memory intent = SrcChainIntent(
            tokenSrcChain,
            amountSrcChain,
            deadline,
            msg.sender
        );

        srcChainIntents[++intentId] = intent;

        emit IntentCreated(tokenDstChain, amountDstChain, chainId, intentId, deadline, receiver, dstChainId);
    }

    function removeIntent(uint256 intentId) external {
        SrcChainIntent memory intent = srcChainIntents[intentId];

        if (msg.sender != intent.creator) revert OnlyCreator();
        if (intent.deadline + CROSS_CHAIN_DELAY > block.timestamp) revert IntentNotExpired();

        // transfer back tokens
        IERC20(intent.tokenSrcChain).transfer(intent.creator, intent.amountSrcChain);

        delete srcChainIntents[intentId];
    }

    // 3) Action made by user (intent can be accepted on dstChain)
    function acceptIntent(uint256 srcChainId, uint256 srcChainIntentId, address receiver) external {
        DstChainIntent memory intent = dstChainIntents[srcChainId][srcChainIntentId];

        // check if it is not expired
        if (intent.deadline < block.timestamp) revert IntentExpired();
        if (receiver == address(0)) receiver = msg.sender;

        // transfer dstChainAmount from accepter to intent creator
        // srcChainAmount will be received by accepter at srcChain
        IERC20(intent.tokenDstChain).transferFrom(msg.sender, intent.receiver, intent.amountDstChain);

        delete dstChainIntents[srcChainId][srcChainIntentId];

        emit BridgeFinalized(intent.srcChainId, intent.srcChainIntentId, receiver);
    }

    // 2) Action triggered by cre workflow
    function _addDstChainIntent(DstChainIntent memory intent) internal {
        dstChainIntents[intent.srcChainId][intent.srcChainIntentId] = intent;
    }
 
    // 4) Action called by user only in the chain where the intent is created
    function _finalizeIntent(uint256 intentId, address receiver) internal {
        SrcChainIntent memory intent = srcChainIntents[intentId];

        // transfer intent token to the intent accepter
        IERC20(intent.tokenSrcChain).transfer(receiver, intent.amountSrcChain);

        //  mark the intent as finalized
        delete srcChainIntents[intentId];
    }

    function _processReport(bytes calldata report) internal override {
        // store the intent in the destination chain
        if (report[0] == 0x00) {
            // decode it
            DstChainIntent memory intent = abi.decode(report[1:], (DstChainIntent));
            _addDstChainIntent(intent);
        } else if (report[0] == 0x01) {
            //  finalize the intent in the src chain
            (uint256 intentId, address receiver) = abi.decode(report[1:], (uint256, address));
            _finalizeIntent(intentId, receiver);
        } else {
            revert WrongReport();
        }
    }
}

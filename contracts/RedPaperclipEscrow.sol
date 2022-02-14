// SPDX-License-Identifier: BSD
pragma solidity ^0.8;

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId)
        external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}

interface IERC721Minter {
    function mintFor(address owner) external;
}

/// @author Lawrence Forman me@merklejerk.com
contract RedPaperclipEscrow721 {

    enum EscrowState {
        Inactive,
        Active,
        Succeeded,
        Expired
    }

    struct TokenAndOwner {
        uint256 tokenId;
        IERC721 token;
        address owner;
        bool redeemed;
    }

    bytes4 constant ONERC721TOKENRECEIVED_MAGIC_BYTES = 0x150b7a02;
    uint256 constant WILDCARD_ERC721_TOKEN_ID =
        0xfd86203450c07395510920ab1eaba02b50c3c10343190d6c9ca5fefd3dcaa970;

    IERC721Minter immutable MINTER;
    IERC721 immutable STARTING_TOKEN;
    uint256 immutable STARTING_TOKEN_ID;
    IERC721 immutable FINAL_TOKEN;
    uint256 immutable FINAL_TOKEN_ID;
    uint256 immutable EXPIRY_TIME;

    TokenAndOwner[] public history;

    constructor(
        IERC721Minter minter,
        IERC721 startingToken,
        uint256 startingTokenId,
        IERC721 finalToken,
        uint256 finalTokenId,
        uint256 ttl
    )
    {
        MINTER = minter;
        STARTING_TOKEN = startingToken;
        STARTING_TOKEN_ID = startingTokenId;
        FINAL_TOKEN = finalToken;
        FINAL_TOKEN_ID = finalTokenId;
        EXPIRY_TIME = block.timestamp + ttl;
    }

    function supportsInterface(bytes4 interfaceID)
        external
        pure
        returns (bool)
    {
        return interfaceID != 0xffffffff &&
            (interfaceID == ONERC721TOKENRECEIVED_MAGIC_BYTES
                || interfaceID == 0x01ffc9a7);
    }

    function onERC721Received(
        address /* operator */,
        address from,
        uint256 tokenId,
        bytes calldata data
    )
        external
        returns (bytes4)
    {
        require(data.length == 0, 'INVALID_DATA');
        // Crappy check that this was actually an NFT.
        require(
            msg.sender != tx.origin &&
            IERC721(msg.sender).ownerOf(tokenId) == address(this),
            'NOT_AN_NFT'
        );
        EscrowState state = getEscrowState();
        require(
            state == EscrowState.Inactive || state == EscrowState.Active,
            'COMPLETED'
        );
        history.push(TokenAndOwner({
            token: IERC721(msg.sender),
            tokenId: tokenId,
            owner: from,
            redeemed: false
        }));
        state = getEscrowState();
        require(
            state == EscrowState.Active || state == EscrowState.Succeeded,
            'NOT_ACTIVE'
        );
        return ONERC721TOKENRECEIVED_MAGIC_BYTES;
    }

    function redeemAll()
        external
    {
        EscrowState state = getEscrowState();
        require(state != EscrowState.Active, 'ACTIVE');
        uint256 n = history.length;
        for (uint256 i = 0; i < n; ++i) {
            _tryRedeemAtHistoryIndex(i, state == EscrowState.Expired);
        }
    }

    function redeemAtHistoryIndex(uint256 idx)
        external
    {
        EscrowState state = getEscrowState();
        require(state != EscrowState.Active, 'ACTIVE');
        require(
            _tryRedeemAtHistoryIndex(idx, state == EscrowState.Expired),
            'FAILED_TO_REDEEM'
        );
    }

    function _tryRedeemAtHistoryIndex(uint256 idx, bool expired)
        private
        returns (bool redeemed)
    {
        uint256 hlen = history.length;
        TokenAndOwner memory cur = history[idx];
        if (cur.owner == msg.sender && !cur.redeemed) {
            history[idx].redeemed = true;
            if (expired) {
                // Expired so just return their original token.
                cur.token.safeTransferFrom(address(this), cur.owner, cur.tokenId);
            } else {
                // Succeeded so transfer the previous contributor's token.
                TokenAndOwner memory prev = idx == 0
                    ? history[hlen - 1] // Wrap around
                    : history[idx - 1];
                prev.token.safeTransferFrom(address(this), cur.owner, prev.tokenId);
                if (address(MINTER) != address(0)) {
                    MINTER.mintFor(cur.owner);
                }
            }
            return true;
        }
        return false;
    }

    function getEscrowState()
        public
        view
        returns (EscrowState)
    {
        uint256 numHistory = history.length;
        if (numHistory > 0) {
            TokenAndOwner storage last = history[numHistory - 1];
            if (isValidFinalToken(last.token, last.tokenId)) {
                return EscrowState.Succeeded;
            }
        }
        if (block.timestamp >= EXPIRY_TIME) {
            return EscrowState.Expired;
        }
        if (numHistory == 0) {
            return EscrowState.Inactive;
        }
        TokenAndOwner storage first = history[0];
        if (first.token == STARTING_TOKEN && first.tokenId == STARTING_TOKEN_ID) {
            return EscrowState.Active;
        }
        return EscrowState.Inactive;
    }

    function isValidFinalToken(IERC721 token, uint256 tokenId)
        public
        view
        returns (bool)
    {
        if (token != FINAL_TOKEN) {
            return false;
        }
        return tokenId == FINAL_TOKEN_ID
            || FINAL_TOKEN_ID == WILDCARD_ERC721_TOKEN_ID;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {Initializable} from "@openzeppelin/contracts-upgradeable-solc8/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable-solc8/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable-solc8/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-solc8/security/PausableUpgradeable.sol";

import {ERC20Burnable} from "@openzeppelin/contracts-solc8/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@synapseprotocol/sol-lib/contracts/solc8/erc20/IERC20.sol";
import {SafeERC20} from "@synapseprotocol/sol-lib/contracts/solc8/erc20/SafeERC20.sol";

import {IVault} from "./interfaces/IVault.sol";
import {IBridge} from "./interfaces/IBridge.sol";

import {IBridgeRouter} from "../router/interfaces/IBridgeRouter.sol";

// solhint-disable reason-string

contract Bridge is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IBridge
{
    using SafeERC20 for IERC20;

    IVault public vault;
    IBridgeRouter public router;

    bytes32 public constant NODEGROUP_ROLE = keccak256("NODEGROUP_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice GAS airdrop amount, that is given for every bridge IN transaction
    uint128 public chainGasAmount;
    /// @notice Maximum amount of GAS units for Swap part of bridge transaction
    uint128 public maxGasForSwap;

    uint256 internal constant UINT_MAX = type(uint256).max;

    /// @dev Some of the tokens are not directly compatible with Synapse:Bridge contract.
    /// For these tokens a wrapper contract is deployed, that will be used
    /// as a "bridge token" in Synapse:Bridge.
    /// The UI, or any other entity, interacting with the BridgeRouter, do NOT need to
    /// know anything about the "bridge wrappers", they should interact as if the
    /// underlying token is the "bridge token".

    /// For example, when calling {depositEVM}, set `token` as underlying token
    /// Also, use underlying token for `destinationSwapParams.path[0]`
    mapping(address => address) internal bridgeWrappers;
    mapping(address => address) internal underlyingTokens;

    /// @dev key is bridgeWrapper here,
    mapping(address => TokenType) public bridgeTokenType;

    function initialize(IVault _vault, uint128 _maxGasForSwap)
        external
        initializer
    {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

        vault = _vault;
        maxGasForSwap = _maxGasForSwap;

        updateChainGasAmount();
    }

    function updateChainGasAmount() public {
        chainGasAmount = uint128(vault.chainGasAmount());
    }

    // -- MODIFIERS --

    modifier bridgeInTx(
        uint256 amount,
        uint256 fee,
        address to
    ) {
        require(amount > fee, "Amount must be greater than fee");

        _;

        _transferGasDrop(to);
    }

    modifier checkSwapParams(SwapParams calldata swapParams) {
        require(
            swapParams.path.length == swapParams.adapters.length + 1,
            "Bridge: len(path)!=len(adapters)+1"
        );

        _;
    }

    modifier checkTokenSupported(address token) {
        require(
            bridgeTokenType[token] != TokenType.NOT_SUPPORTED,
            "Bridge: token is not supported"
        );

        _;
    }

    // -- VIEWS --

    function getBridgeToken(address bridgeToken)
        public
        view
        returns (address actualBridgeToken)
    {
        actualBridgeToken = bridgeWrappers[bridgeToken];
        if (actualBridgeToken == address(0)) {
            actualBridgeToken = bridgeToken;
        }
    }

    function getUnderlyingToken(address bridgeToken)
        public
        view
        returns (address actualUnderlyingToken)
    {
        actualUnderlyingToken = underlyingTokens[bridgeToken];
        if (actualUnderlyingToken == address(0)) {
            actualUnderlyingToken = bridgeToken;
        }
    }

    // -- RECOVER TOKEN/GAS --

    /**
        @notice Recover GAS from the contract
     */
    function recoverGAS() external onlyRole(GOVERNANCE_ROLE) {
        uint256 amount = address(this).balance;
        require(amount != 0, "Nothing to recover");

        emit Recovered(address(0), amount);
        //solhint-disable-next-line
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "GAS transfer failed");
    }

    /**
        @notice Recover a token from the contract
        @param token token to recover
     */
    function recoverERC20(IERC20 token) external onlyRole(GOVERNANCE_ROLE) {
        uint256 amount = token.balanceOf(address(this));
        require(amount != 0, "Nothing to recover");

        emit Recovered(address(token), amount);
        //solhint-disable-next-line
        token.safeTransfer(msg.sender, amount);
    }

    // -- RESTRICTED SETTERS --

    /**
        @notice Register a bridge token for later usage on the bridge
        @dev Most of the time `bridgeToken` will be directly compatible with Synapse: Bridge,
        i.e. can be safely used as deposit-withdraw, or can be used as mint-burn, if both
        {mint} and {burnFrom} are implemented correctly, and `Vault` has a Minter role.
        In this case, `bridgeToken == bridgeWrapper`.

        In some cases, an intermediate contract is required to achieve that, it is called a Bridge Wrapper.
        In this case, `bridgeToken != bridgeWrapper`.

        @param bridgeToken token that will be bridged
        @param bridgeWrapper token that Synapse:Bridge will use for bridging
        @param tokenType mint-burn or deposit-withdraw
     */
    function registerBridgeToken(
        address bridgeToken,
        address bridgeWrapper,
        TokenType tokenType
    ) external onlyRole(GOVERNANCE_ROLE) {
        address _oldUnderlying = underlyingTokens[bridgeWrapper];
        require(
            _oldUnderlying == address(0) || _oldUnderlying == bridgeWrapper,
            "BridgeWrapper is linked to another bridge token"
        );

        // Delete record of underlying from bridgeToken's "old bridge wrapper",
        // if there is one
        address _oldWrapper = bridgeWrappers[bridgeToken];
        if (_oldWrapper != address(0) && _oldWrapper != bridgeWrapper) {
            underlyingTokens[_oldWrapper] = address(0);
            bridgeTokenType[_oldWrapper] = TokenType.NOT_SUPPORTED;
        }

        // Save record for bridgeWrapper's underlying token
        if (_oldUnderlying == address(0)) {
            underlyingTokens[bridgeWrapper] = bridgeToken;
        }

        // Save record for bridgeToken's bridge wrapper
        bridgeWrappers[bridgeToken] = bridgeWrapper;

        bridgeTokenType[bridgeWrapper] = tokenType;

        emit BridgeTokenRegistered(bridgeToken, bridgeWrapper, tokenType);
    }

    function setMaxGasForSwap(uint128 _maxGasForSwap)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        maxGasForSwap = _maxGasForSwap;
    }

    function setRouter(IBridgeRouter _router)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        router = _router;
    }

    function setTokenBridgeType(address token, TokenType bridgeType)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        bridgeTokenType[token] = bridgeType;
    }

    // -- BRIDGE OUT FUNCTIONS: to EVM chains --

    function bridgeToEVM(
        address to,
        uint256 chainId,
        address token,
        uint256 amount,
        SwapParams calldata destinationSwapParams
    ) external {
        // First, use Bridge Wrapper, if there is one for `token`
        token = getBridgeToken(token);
        // Then, do bridging
        _bridgeToEVM(to, chainId, token, amount, destinationSwapParams);
    }

    function bridgeMaxToEVM(
        address to,
        uint256 chainId,
        address token,
        SwapParams calldata destinationSwapParams
    ) external {
        // First, use Bridge Wrapper, if there is one for `token`
        token = getBridgeToken(token);
        // Then, determine how much Bridge call pull from caller
        uint256 amount = _getMaxAmount(token);
        // Finally, do bridging
        _bridgeToEVM(to, chainId, token, amount, destinationSwapParams);
    }

    function _bridgeToEVM(
        address to,
        uint256 chainId,
        address token,
        uint256 amount,
        SwapParams calldata destinationSwapParams
    )
        internal
        checkSwapParams(destinationSwapParams)
        checkTokenSupported(token)
    {
        (
            bridgeTokenType[token] == TokenType.MINT_BURN
                ? _redeemEVM
                : _depositEVM
        )(to, chainId, token, amount, destinationSwapParams);
    }

    // -- BRIDGE OUT FUNCTIONS: to non-EVM chain --

    function bridgeToNonEVM(
        bytes32 to,
        uint256 chainId,
        address token,
        uint256 amount
    ) external {
        // First, use Bridge Wrapper, if there is one for `token`
        token = getBridgeToken(token);
        // Then, do bridging
        _bridgeToNonEVM(to, chainId, token, amount);
    }

    function bridgeMaxToNonEVM(
        bytes32 to,
        uint256 chainId,
        address token
    ) external {
        // First, use Bridge Wrapper, if there is one for `token`
        token = getBridgeToken(token);
        // Then, determine how much Bridge call pull from caller
        uint256 amount = _getMaxAmount(token);
        // Finally, do bridging
        _bridgeToNonEVM(to, chainId, token, amount);
    }

    function _bridgeToNonEVM(
        bytes32 to,
        uint256 chainId,
        address token,
        uint256 amount
    ) internal checkTokenSupported(token) {
        (
            bridgeTokenType[token] == TokenType.MINT_BURN
                ? _redeemNonEVM
                : _depositNonEVM
        )(to, chainId, token, amount);
    }

    // -- BRIDGE OUT FUNCTIONS: Deposit internal implementation --

    function _depositEVM(
        address to,
        uint256 chainId,
        address token,
        uint256 amount,
        SwapParams calldata destinationSwapParams
    ) internal {
        // First, deposit to Vault. Use verified deposit amount for bridging
        amount = _depositToVault(token, amount);
        // Then, emit corresponding Bridge Event
        emit TokenDepositEVM(
            to,
            chainId,
            IERC20(token),
            amount,
            destinationSwapParams.minAmountOut,
            destinationSwapParams.path,
            destinationSwapParams.adapters,
            destinationSwapParams.deadline
        );
    }

    function _depositNonEVM(
        bytes32 to,
        uint256 chainId,
        address token,
        uint256 amount
    ) internal {
        // First, deposit to Vault. Use verified deposit amount for bridging
        amount = _depositToVault(token, amount);
        // Then, emit corresponding Bridge Event
        emit TokenDepositNonEVM(to, chainId, IERC20(token), amount);
    }

    // -- BRIDGE OUT FUNCTIONS: Redeem internal implementation --

    function _redeemEVM(
        address to,
        uint256 chainId,
        address token,
        uint256 amount,
        SwapParams calldata destinationSwapParams
    ) internal {
        // First, burn tokens from caller. Use verified deposit amount for bridging
        amount = _burnFromCaller(token, amount);
        // Then, emit corresponding Bridge Event
        emit TokenRedeemEVM(
            to,
            chainId,
            ERC20Burnable(token),
            amount,
            destinationSwapParams.minAmountOut,
            destinationSwapParams.path,
            destinationSwapParams.adapters,
            destinationSwapParams.deadline
        );
    }

    function _redeemNonEVM(
        bytes32 to,
        uint256 chainId,
        address token,
        uint256 amount
    ) internal {
        // First, burn tokens from caller. Use verified deposit amount for bridging
        amount = _burnFromCaller(token, amount);
        // Then, emit corresponding Bridge Event
        emit TokenRedeemNonEVM(to, chainId, ERC20Burnable(token), amount);
    }

    // -- BRIDGE IN FUNCTIONS --

    function bridgeIn(
        address to,
        IERC20 token,
        uint256 amount,
        uint256 fee,
        bool isMint,
        SwapParams calldata swapParams,
        bytes32 kappa
    )
        external
        onlyRole(NODEGROUP_ROLE)
        nonReentrant
        whenNotPaused
        bridgeInTx(amount, fee, to)
    {
        // First, get the amount post fees
        amount = amount - fee;

        SwapResult memory swapResult;

        if (
            _isSwapPresent(swapParams) &&
            !_isDeadlineFailed(swapParams.deadline)
        ) {
            // If there's a swap, and deadline check is passed,
            // mint|withdraw bridged tokens to Router
            (isMint ? vault.mintToken : vault.withdrawToken)(
                address(router),
                token,
                amount,
                fee,
                kappa
            );

            // Then handle the swap part
            swapResult = _handleSwap(to, token, amount, swapParams);
        } else {
            // If there's no swap, or deadline check is not passed,
            // mint|withdraw bridged token to needed address
            (isMint ? vault.mintToken : vault.withdrawToken)(
                to,
                token,
                amount,
                fee,
                kappa
            );

            // If token is a Bridge Wrapper, use underlying for the Event Log
            address underlyingToken = getUnderlyingToken(address(token));
            swapResult = SwapResult(IERC20(underlyingToken), amount);
        }

        // Finally, emit BridgeIn Event
        emit TokenBridgedIn(
            to,
            token,
            amount + fee,
            fee,
            swapResult.tokenReceived,
            swapResult.amountReceived,
            isMint,
            kappa
        );
    }

    // -- INTERNAL HELPERS --

    function _burnFromCaller(address tokenAddress, uint256 amount)
        internal
        returns (uint256 amountBurnt)
    {
        ERC20Burnable token = ERC20Burnable(tokenAddress);
        uint256 balanceBefore = token.balanceOf(msg.sender);
        token.burnFrom(msg.sender, amount);
        amountBurnt = balanceBefore - token.balanceOf(msg.sender);
        require(amountBurnt > 0, "No burn happened");
    }

    function _depositToVault(address tokenAddress, uint256 amount)
        internal
        returns (uint256 amountDeposited)
    {
        IERC20 token = IERC20(tokenAddress);
        uint256 balanceBefore = token.balanceOf(address(vault));
        token.safeTransferFrom(msg.sender, address(vault), amount);
        amountDeposited = token.balanceOf(address(vault)) - balanceBefore;
        require(amountDeposited > 0, "No deposit happened");
    }

    function _getMaxAmount(address tokenAddress)
        internal
        view
        returns (uint256)
    {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(msg.sender);
        uint256 allowance = token.allowance(msg.sender, address(this));
        return balance < allowance ? balance : allowance;
    }

    function _handleSwap(
        address to,
        IERC20 token,
        uint256 amountPostFee,
        SwapParams calldata swapParams
    ) internal returns (SwapResult memory swapResult) {
        // We're limiting amount of gas forwarded to Router,
        // so we always have some leftover gas to transfer
        // bridged token, should the swap run out of gas
        try
            router.postBridgeSwap{gas: maxGasForSwap}(
                amountPostFee,
                swapParams,
                to
            )
        returns (uint256 _amountOut) {
            swapResult = SwapResult(
                IERC20(swapParams.path[swapParams.path.length - 1]),
                _amountOut
            );
        } catch {
            // If token is a Bridge Wrapper, use underlying for returning
            address underlyingToken = getUnderlyingToken(address(token));
            swapResult = SwapResult(IERC20(underlyingToken), amountPostFee);
            router.refundToAddress(underlyingToken, amountPostFee, to);
        }
    }

    function _isDeadlineFailed(uint256 deadline) internal view returns (bool) {
        //solhint-disable-next-line
        return block.timestamp > deadline;
    }

    function _isSwapPresent(SwapParams calldata params)
        internal
        pure
        returns (bool)
    {
        return params.adapters.length > 0;
    }

    function _transferGasDrop(address to) internal {
        if (address(this).balance >= chainGasAmount) {
            //solhint-disable-next-line
            (bool success, ) = to.call{value: chainGasAmount}("");
        }
    }
}

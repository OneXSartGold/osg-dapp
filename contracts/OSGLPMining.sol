// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// File: @openzeppelin/contracts/access/Ownable.sol


// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// File: @openzeppelin/contracts/utils/StorageSlot.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}

// File: @openzeppelin/contracts/utils/ReentrancyGuard.sol


// OpenZeppelin Contracts (last updated v5.5.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 *
 * IMPORTANT: Deprecated. This storage-based reentrancy guard will be removed and replaced
 * by the {ReentrancyGuardTransient} variant in v6.0.
 *
 * @custom:stateless
 */
abstract contract ReentrancyGuard {
    using StorageSlot for bytes32;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    /**
     * @dev A `view` only version of {nonReentrant}. Use to block view functions
     * from being called, preventing reading from inconsistent contract state.
     *
     * CAUTION: This is a "view" modifier and does not change the reentrancy
     * status. Use it only on view functions. For payable or non-payable functions,
     * use the standard {nonReentrant} modifier instead.
     */
    modifier nonReentrantView() {
        _nonReentrantBeforeView();
        _;
    }

    function _nonReentrantBeforeView() private view {
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        _nonReentrantBeforeView();

        // Any calls to nonReentrant after this point will fail
        _reentrancyGuardStorageSlot().getUint256Slot().value = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _reentrancyGuardStorageSlot().getUint256Slot().value == ENTERED;
    }

    function _reentrancyGuardStorageSlot() internal pure virtual returns (bytes32) {
        return REENTRANCY_GUARD_STORAGE;
    }
}

// File: @openzeppelin/contracts/utils/Pausable.sol


// OpenZeppelin Contracts (last updated v5.3.0) (utils/Pausable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
    bool private _paused;

    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    /**
     * @dev The operation failed because the contract is paused.
     */
    error EnforcedPause();

    /**
     * @dev The operation failed because the contract is not paused.
     */
    error ExpectedPause();

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        if (paused()) {
            revert EnforcedPause();
        }
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        if (!paused()) {
            revert ExpectedPause();
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

pragma solidity >=0.4.16;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// File: @openzeppelin/contracts/interfaces/IERC20.sol


// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC20.sol)

pragma solidity >=0.4.16;


// File: @openzeppelin/contracts/utils/introspection/IERC165.sol


// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/IERC165.sol)

pragma solidity >=0.4.16;

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// File: @openzeppelin/contracts/interfaces/IERC165.sol


// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC165.sol)

pragma solidity >=0.4.16;


// File: @openzeppelin/contracts/interfaces/IERC1363.sol


// OpenZeppelin Contracts (last updated v5.4.0) (interfaces/IERC1363.sol)

pragma solidity >=0.6.2;



/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// File: @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol


// OpenZeppelin Contracts (last updated v5.5.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.20;



/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        if (!_safeTransfer(token, to, value, true)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        if (!_safeTransferFrom(token, from, to, value, true)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Variant of {safeTransfer} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        return _safeTransfer(token, to, value, false);
    }

    /**
     * @dev Variant of {safeTransferFrom} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        return _safeTransferFrom(token, from, to, value, false);
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        if (!_safeApprove(token, spender, value, false)) {
            if (!_safeApprove(token, spender, 0, true)) revert SafeERC20FailedOperation(address(token));
            if (!_safeApprove(token, spender, value, true)) revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that relies on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that relies on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Oppositely, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity `token.transfer(to, value)` call, relaxing the requirement on the return value: the
     * return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param to The recipient of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeTransfer(IERC20 token, address to, uint256 value, bool bubble) private returns (bool success) {
        bytes4 selector = IERC20.transfer.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(to, shr(96, not(0))))
            mstore(0x24, value)
            success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
        }
    }

    /**
     * @dev Imitates a Solidity `token.transferFrom(from, to, value)` call, relaxing the requirement on the return
     * value: the return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param from The sender of the tokens
     * @param to The recipient of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value,
        bool bubble
    ) private returns (bool success) {
        bytes4 selector = IERC20.transferFrom.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(from, shr(96, not(0))))
            mstore(0x24, and(to, shr(96, not(0))))
            mstore(0x44, value)
            success := call(gas(), token, 0, 0x00, 0x64, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
            mstore(0x60, 0)
        }
    }

    /**
     * @dev Imitates a Solidity `token.approve(spender, value)` call, relaxing the requirement on the return value:
     * the return value is optional (but if data is returned, it must not be false).
     *
     * @param token The token targeted by the call.
     * @param spender The spender of the tokens
     * @param value The amount of token to transfer
     * @param bubble Behavior switch if the transfer call reverts: bubble the revert reason or return a false boolean.
     */
    function _safeApprove(IERC20 token, address spender, uint256 value, bool bubble) private returns (bool success) {
        bytes4 selector = IERC20.approve.selector;

        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, selector)
            mstore(0x04, and(spender, shr(96, not(0))))
            mstore(0x24, value)
            success := call(gas(), token, 0, 0x00, 0x44, 0x00, 0x20)
            // if call success and return is true, all is good.
            // otherwise (not success or return is not true), we need to perform further checks
            if iszero(and(success, eq(mload(0x00), 1))) {
                // if the call was a failure and bubble is enabled, bubble the error
                if and(iszero(success), bubble) {
                    returndatacopy(fmp, 0x00, returndatasize())
                    revert(fmp, returndatasize())
                }
                // if the return value is not true, then the call is only successful if:
                // - the token address has code
                // - the returndata is empty
                success := and(success, and(iszero(returndatasize()), gt(extcodesize(token), 0)))
            }
            mstore(0x40, fmp)
        }
    }
}

// File: OSGLPMining.sol


pragma solidity 0.8.34;






/*
 * ======================================================================
 *  OSGLPMining v6
 *  Successor to v5 (0xF534adff723b5c89AD86343B9E4b1E64E6c82aba).
 * ======================================================================
 *
 *  WHY v6 -- four fixes, all found by re-reading the deployed v5 source:
 *
 *  FIX 1 -- DEPOSITED LP COULD BECOME UNWITHDRAWABLE.
 *    In v5, withdraw() called _settlePending() which called
 *    pool.distribute() fail-loud. So ANY condition that blocked the
 *    reward payout also blocked the LP withdrawal: RewardPool paused,
 *    emissionStopped, this contract de-registered as distributor,
 *    daily Mining cap hit, per-block cooldown collision, RewardStorage
 *    paused -- and, permanently, RewardPool.emissionEndTime passing
 *    (distribute() has an emissionActive modifier and emissionEndTime
 *    is immutable, so after ~June 2041 every distribute() reverts
 *    forever, locking all deposited LP with no recovery path).
 *    v6 fixes this two ways:
 *      (a) withdraw() now banks the accrued reward FIRST via _accrue()
 *          and only then attempts the payout inside try/catch, so a
 *          failed payout blocks neither the LP transfer nor the reward.
 *      (b) emergencyWithdraw() returns LP with NO distribute() call at
 *          all, and is deliberately NOT whenNotPaused, so depositors
 *          can always exit even if the owner is unavailable or the
 *          wider reward system is permanently down. It still refreshes
 *          the tier rate first, but through try/catch, so the user is
 *          credited in full when RewardPool is healthy without the exit
 *          ever depending on it.
 *
 *  FIX 2 -- 10,000 OSG PERMANENT LOCK.
 *    v5's _settlePending had require(pending <= MAX_SINGLE_ALLOC).
 *    Once a user's pending crossed 10,000 OSG, deposit(), withdraw()
 *    AND claim() all reverted forever -- accRewardPerShare can never be
 *    reduced, and no admin function could clear it. The revert string
 *    said "contact support" but no support function existed.
 *    v6 pays out in capped chunks instead of reverting, mirroring
 *    RewardPool v2's own chunked-claim approach.
 *
 *  FIX 3 -- UNPAID REWARD IS NOW TRACKED EXPLICITLY.
 *    New UserTierInfo.unpaid field, filled by _accrue(). rewardDebt
 *    always advances to the full accumulated figure (so lpAmount
 *    changes stay safe with the standard staking formula), while
 *    anything accrued but not yet sent sits in unpaid and is paid on
 *    the next settlement.
 *
 *    IMPORTANT ORDERING RULE: _accrue() must run in the OUTER call
 *    frame, before _trySettle(). _trySettle() deliberately swallows a
 *    reverting payout, and that revert rolls back everything the inner
 *    call touched. If the accrual happened only inside that inner call,
 *    a failed payout would roll it back while the caller went on to
 *    recompute rewardDebt against the NEW lpAmount -- silently erasing
 *    the pending reward. Accruing outside first makes the rollback
 *    affect only the payout attempt itself.
 *
 *  FIX 4 -- lpToken IS NOW PER-TIER, NOT CONTRACT-WIDE.
 *    v5 had IERC20 public immutable lpToken, so every tier had to use
 *    the same LP token and a second pair (e.g. OSG/USDT) would have
 *    required a whole new contract + new distributor slot. In v6 each
 *    tier carries its own lpToken, so a future pair is just a new tier.
 *    An existing tier's lpToken can only be changed while that tier
 *    holds zero deposits.
 *
 * ----------------------------------------------------------------------
 *  UNCHANGED FROM v5 (deliberately -- these were correct):
 *   - LP-amount-based accounting (not discrete slots)
 *   - tierWeightBps budget split across tiers, sum <= 100%
 *   - _settleAllActiveTiers() hygiene before any rate change
 *   - Referral hooks wrapped in try/catch, never block Mining
 *   - 24h first-withdraw lock (applies to emergencyWithdraw too)
 *   - No unbounded loops anywhere
 *
 *  ARCHITECTURE REMINDER:
 *   RewardPool.setDistributor(addr, cat) binds ONE address to ONE
 *   category. This contract is category 2 (Mining) only. All referral
 *   and rank-bonus logic lives in the companion OSGLPReferral, which is
 *   registered separately as category 3.
 * ======================================================================
 */

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
    /// RewardPool.miningPercent is a public state var (0-100, NOT bps) --
    /// read live instead of hardcoding the 40% split.
    function miningPercent() external view returns (uint256);
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
}

/// Minimal hook interface the companion Referral contract must implement.
interface IOSGLPReferral {
    function onLiquidityChange(address depositor, uint256 lpDelta, bool isAdd) external;
    function onRewardClaimed(address user, uint256 rewardAmount) external;
}

contract OSGLPMining is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================
    uint8   public constant CAT_MINING  = 2;
    uint256 public constant BPS_DENOM   = 10_000;
    uint256 public constant ABSOLUTE_MAX_SHARE_BPS = 9_000; // 90% hard ceiling
    /// Applies to the wallet's first-ever deposit, and gates BOTH
    /// withdraw() and emergencyWithdraw() -- confirmed design choice.
    uint256 public constant FIRST_WITHDRAW_LOCK = 24 hours;
    /// Mirrors RewardPool.MAX_SINGLE_ALLOC (10,000 OSG). v6 CAPS the
    /// payout at this value instead of reverting above it.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;
    uint256 public constant TIER_COUNT = 5;

    // ====================== IMMUTABLES ======================
    IOSGRewardPool public immutable pool;

    // ====================== REFERRAL HOOK TARGET ======================
    IOSGLPReferral public referralContract;

    // ====================== MINING SHARE (owner-adjustable) ======================
    uint256 public miningShareBps = 50;    // 0.5% of the Mining bucket
    uint256 public maxShareBps    = 5_000; // 50% ceiling, up to ABSOLUTE_MAX

    // ====================== TIERS ======================
    enum TierId { T1, T2, T3, T4, T5 }

    struct TierConfig {
        address lpToken;           // FIX 4: per-tier LP token
        uint256 minDeposit;        // minimum LP per deposit call
        uint256 capacityLp;        // total LP capacity for this tier
        uint256 totalDepositedLp;  // currently deposited LP, this tier
        bool    active;
        uint256 tierWeightBps;     // share of getLpMiningDailyBudget()
        uint256 accRewardPerShare; // cumulative reward per LP unit, 1e18
        uint256 lastRewardTime;
    }
    mapping(TierId => TierConfig) public tiers;
    uint256 public totalTierWeightBps;

    struct UserTierInfo {
        uint256 lpAmount;
        uint256 rewardDebt;
        uint256 unpaid;    // FIX 3: accrued but not yet distributed
    }
    mapping(address => mapping(TierId => UserTierInfo)) public userTier;

    /// Set once on a wallet's very first deposit (any tier), never updated.
    mapping(address => uint256) public firstDepositTime;

    // ====================== EVENTS ======================
    event Deposited(address indexed user, TierId tier, uint256 lpAmount);
    event Withdrawn(address indexed user, TierId tier, uint256 lpAmount);
    event EmergencyWithdrawn(address indexed user, TierId tier, uint256 lpAmount, uint256 unpaidKept);
    event MiningClaimed(address indexed user, TierId tier, uint256 amount);
    event SettlementDeferred(address indexed user, TierId tier, uint256 unpaidTotal, string reason);
    event PayoutCapped(address indexed user, TierId tier, uint256 paid, uint256 remaining);
    event ReferralHookFailed(address indexed user, string what, bytes reason);
    event TierConfigUpdated(TierId tier, uint256 minDeposit, uint256 capacityLp, bool active);
    event TierLpTokenUpdated(TierId indexed tier, address indexed lpToken);
    event MiningShareUpdated(uint256 newBps, address indexed by);
    event TierWeightUpdated(TierId indexed tier, uint256 newWeightBps, uint256 totalWeightBps);
    event ReferralContractUpdated(address indexed newContract);

    constructor(address _lpToken, address _pool, address _owner) Ownable(_owner) {
        require(_lpToken.code.length > 0, "lpToken not contract");
        require(_pool.code.length    > 0, "pool not contract");
        pool = IOSGRewardPool(_pool);

        // T1 active at launch. Values below match the live v5
        // configuration on mainnet (min 100 LP, capacity 2500 LP,
        // verified via tiers(0) on 29 July 2026) so the migration is
        // like-for-like.
        tiers[TierId.T1] = TierConfig({
            lpToken: _lpToken,
            minDeposit: 100 ether,
            capacityLp: 2500 ether,
            totalDepositedLp: 0,
            active: true,
            tierWeightBps: BPS_DENOM, // 100% -- only active tier at launch
            accRewardPerShare: 0,
            lastRewardTime: block.timestamp
        });
        totalTierWeightBps = BPS_DENOM;
    }

    // ====================== DEPOSIT / WITHDRAW / CLAIM ======================

    function deposit(TierId tierId, uint256 lpAmount) external nonReentrant whenNotPaused {
        TierConfig storage t = tiers[tierId];
        require(t.active, "tier not active");
        require(t.lpToken != address(0), "tier lpToken not set");
        require(lpAmount >= t.minDeposit, "below minimum deposit");
        require(t.totalDepositedLp + lpAmount <= t.capacityLp, "exceeds tier capacity");

        _updateTierRewards(tierId);
        _accrue(msg.sender, tierId);      // bank first -- see FIX 3 ordering rule
        _trySettle(msg.sender, tierId);

        IERC20(t.lpToken).safeTransferFrom(msg.sender, address(this), lpAmount);

        UserTierInfo storage u = userTier[msg.sender][tierId];
        u.lpAmount += lpAmount;
        u.rewardDebt = (u.lpAmount * t.accRewardPerShare) / 1e18;
        t.totalDepositedLp += lpAmount;

        if (firstDepositTime[msg.sender] == 0) {
            firstDepositTime[msg.sender] = block.timestamp;
        }

        _notifyLiquidityChange(msg.sender, lpAmount, true);

        emit Deposited(msg.sender, tierId, lpAmount);
    }

    /// FIX 1(a): the accrual is banked into unpaid BEFORE the payout is
    /// attempted, and the payout itself is wrapped in try/catch. So a
    /// failed payout blocks neither the LP transfer nor the reward --
    /// the reward simply waits in unpaid until the next claim().
    function withdraw(TierId tierId, uint256 lpAmount) external nonReentrant whenNotPaused {
        require(lpAmount > 0, "zero amount");
        require(
            block.timestamp >= firstDepositTime[msg.sender] + FIRST_WITHDRAW_LOCK,
            "24h lock active on first deposit"
        );

        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[msg.sender][tierId];
        require(u.lpAmount >= lpAmount, "insufficient balance");

        _updateTierRewards(tierId);
        _accrue(msg.sender, tierId);      // bank first -- see FIX 3 ordering rule
        _trySettle(msg.sender, tierId);

        u.lpAmount -= lpAmount;
        u.rewardDebt = (u.lpAmount * t.accRewardPerShare) / 1e18;
        t.totalDepositedLp -= lpAmount;

        IERC20(t.lpToken).safeTransfer(msg.sender, lpAmount);

        _notifyLiquidityChange(msg.sender, lpAmount, false);

        emit Withdrawn(msg.sender, tierId, lpAmount);
    }

    /// FIX 1(b): unconditional exit. Makes NO call to RewardPool, is NOT
    /// whenNotPaused, and cannot be blocked by anything outside this
    /// contract. Any accrued-but-unpaid reward is KEPT (not burned) and
    /// stays claimable via claim() if/when the reward system recovers.
    /// The 24h first-deposit lock still applies, by design.
    function emergencyWithdraw(TierId tierId) external nonReentrant {
        require(
            block.timestamp >= firstDepositTime[msg.sender] + FIRST_WITHDRAW_LOCK,
            "24h lock active on first deposit"
        );

        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[msg.sender][tierId];

        uint256 amount = u.lpAmount;
        require(amount > 0, "nothing deposited");

        // Bring accRewardPerShare up to date so the user is credited for
        // time elapsed since the tier was last touched -- but do it via
        // try/catch, because _updateTierRewards() reads the budget from
        // RewardPool. If RewardPool is unreachable the update is skipped
        // and the exit still succeeds, which is the whole point of this
        // function. Then bank the accrual, BEFORE lpAmount is zeroed.
        _tryUpdateTierRewards(tierId);
        _accrue(msg.sender, tierId);

        u.lpAmount   = 0;
        u.rewardDebt = 0;
        t.totalDepositedLp -= amount;

        IERC20(t.lpToken).safeTransfer(msg.sender, amount);

        _notifyLiquidityChange(msg.sender, amount, false);

        emit EmergencyWithdrawn(msg.sender, tierId, amount, u.unpaid);
    }

    /// Claims pending mining reward for one tier. Fail-loud on purpose:
    /// if the user explicitly asked to claim and it cannot be paid, they
    /// should see the reason rather than a silent no-op.
    function claim(TierId tierId) external nonReentrant whenNotPaused {
        _updateTierRewards(tierId);
        _settlePending(msg.sender, tierId);
    }

    // ====================== INTERNAL -- REWARD SETTLEMENT ======================

    /// Banks newly accrued reward into unpaid and advances rewardDebt.
    /// Touches NO external contract, so it can never revert. Calling
    /// this in the outer frame before _trySettle() is what keeps a
    /// failed payout from erasing the user's pending reward.
    function _accrue(address user, TierId tierId) internal {
        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[user][tierId];
        if (u.lpAmount == 0) return;
        uint256 accumulated = (u.lpAmount * t.accRewardPerShare) / 1e18;
        if (accumulated > u.rewardDebt) {
            u.unpaid += accumulated - u.rewardDebt;
        }
        u.rewardDebt = accumulated;
    }

    /// Self-call wrapper letting emergencyWithdraw() refresh the tier
    /// rate without inheriting RewardPool's failure modes.
    function _updateTierRewardsExternal(TierId tierId) external {
        require(msg.sender == address(this), "internal only");
        _updateTierRewards(tierId);
    }

    function _tryUpdateTierRewards(TierId tierId) internal {
        try this._updateTierRewardsExternal(tierId) {
            // rate refreshed
        } catch {
            // RewardPool unreachable -- proceed with the stale rate
            // rather than blocking the emergency exit.
        }
    }

    /// Self-call wrapper so deposit()/withdraw() can try/catch the
    /// payout. A revert inside rolls back only what the inner call
    /// touched -- the _accrue() done by the caller survives.
    /// NOTE: intentionally NOT nonReentrant -- it is invoked via
    /// this._settleExternal(...) from inside a nonReentrant function,
    /// and is access-gated to this contract only.
    function _settleExternal(address user, TierId tierId) external {
        require(msg.sender == address(this), "internal only");
        _settlePending(user, tierId);
    }

    function _trySettle(address user, TierId tierId) internal {
        try this._settleExternal(user, tierId) {
            // paid (or nothing to pay)
        } catch Error(string memory reason) {
            emit SettlementDeferred(user, tierId, userTier[user][tierId].unpaid, reason);
        } catch (bytes memory lowLevelData) {
            emit SettlementDeferred(
                user, tierId, userTier[user][tierId].unpaid,
                lowLevelData.length == 0 ? "out of gas or no reason" : "low-level revert"
            );
        }
    }

    /// FIX 2 + FIX 3. Accrues, then pays out as much of unpaid as both
    /// caps allow; the remainder stays in unpaid for a later call.
    function _settlePending(address user, TierId tierId) internal {
        UserTierInfo storage u = userTier[user][tierId];

        _accrue(user, tierId);

        if (u.unpaid == 0) return;

        // Cap by BOTH limits. MAX_SINGLE_ALLOC alone is not enough: the
        // Mining bucket's whole daily budget (~2,352 OSG at a 40% split
        // of 5,881/day, up to ~9,409 with 3 days of carry) is smaller
        // than MAX_SINGLE_ALLOC, so a 10,000 payout would ALWAYS revert
        // with "Mining cap exceeded". Reading miningAvail live keeps the
        // payout inside whatever RewardPool can actually distribute today.
        uint256 payout = u.unpaid > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : u.unpaid;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (payout > miningAvail) payout = miningAvail;
        require(payout > 0, "no mining budget available today");

        u.unpaid -= payout;

        pool.distribute(user, payout, CAT_MINING);
        emit MiningClaimed(user, tierId, payout);

        if (u.unpaid > 0) {
            emit PayoutCapped(user, tierId, payout, u.unpaid);
        }

        _notifyClaim(user, payout);
    }

    function _updateTierRewards(TierId tierId) internal {
        TierConfig storage t = tiers[tierId];
        if (block.timestamp <= t.lastRewardTime || t.totalDepositedLp == 0) {
            t.lastRewardTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - t.lastRewardTime;
        uint256 reward = (getTierDailyBudget(tierId) * elapsed) / 1 days;
        if (reward > 0) {
            t.accRewardPerShare += (reward * 1e18) / t.totalDepositedLp;
        }
        t.lastRewardTime = block.timestamp;
    }

    /// Settles every active tier at its OLD rate before any change that
    /// affects shared reward-rate math. Bounded 5-iteration loop.
    function _settleAllActiveTiers() internal {
        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            if (tiers[all[i]].active) {
                _updateTierRewards(all[i]);
            }
        }
    }

    // ====================== VIEW -- BUDGET ======================

    /// LP Mining's total daily OSG budget across ALL tiers.
    /// RewardPool.miningPercent is 0-100; miningShareBps is bps.
    function getLpMiningDailyBudget() public view returns (uint256) {
        ( , , , , , , uint256 dailyBase) = pool.getTodayStats();
        uint256 miningPct    = pool.miningPercent();
        uint256 miningBucket = (dailyBase * miningPct) / 100;
        return (miningBucket * miningShareBps) / BPS_DENOM;
    }

    function getTierDailyBudget(TierId tierId) public view returns (uint256) {
        return (getLpMiningDailyBudget() * tiers[tierId].tierWeightBps) / BPS_DENOM;
    }

    /// Includes any carried-over unpaid from a capped or deferred payout.
    function pendingMiningReward(address user, TierId tierId) public view returns (uint256) {
        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[user][tierId];

        uint256 total = u.unpaid;
        if (u.lpAmount == 0) return total;

        uint256 acc = t.accRewardPerShare;
        if (block.timestamp > t.lastRewardTime && t.totalDepositedLp > 0) {
            uint256 elapsed = block.timestamp - t.lastRewardTime;
            uint256 reward = (getTierDailyBudget(tierId) * elapsed) / 1 days;
            acc += (reward * 1e18) / t.totalDepositedLp;
        }
        uint256 accumulated = (u.lpAmount * acc) / 1e18;
        if (accumulated > u.rewardDebt) {
            total += accumulated - u.rewardDebt;
        }
        return total;
    }

    /// How much of pendingMiningReward() the NEXT settlement can actually
    /// send right now, capped by MAX_SINGLE_ALLOC AND by today's remaining
    /// Mining budget. Returns 0 when nothing can be paid today -- useful
    /// for honest UI messaging ("X OSG accrued, Y payable now").
    function nextPayoutChunk(address user, TierId tierId) external view returns (uint256) {
        uint256 total = pendingMiningReward(user, tierId);
        if (total > MAX_SINGLE_ALLOC) total = MAX_SINGLE_ALLOC;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        return total > miningAvail ? miningAvail : total;
    }

    // ====================== INTERNAL -- REFERRAL NOTIFICATIONS ======================
    // Both hooks stay in try/catch: a referral-side failure must NEVER
    // block a user's own deposit/withdraw/claim/emergency exit.

    function _notifyLiquidityChange(address depositor, uint256 lpDelta, bool isAdd) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onLiquidityChange(depositor, lpDelta, isAdd) {
            // ok
        } catch (bytes memory reason) {
            emit ReferralHookFailed(depositor, "onLiquidityChange", reason);
        }
    }

    function _notifyClaim(address user, uint256 rewardAmount) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onRewardClaimed(user, rewardAmount) {
            // ok
        } catch (bytes memory reason) {
            emit ReferralHookFailed(user, "onRewardClaimed", reason);
        }
    }

    // ====================== VIEW -- HEALTH ======================

    function isWiredForMining() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_MINING
            && pool.distributorActive(address(this));
    }

    /// One-call diagnosis for the UI: explains WHY a reward settlement
    /// would currently fail, so the app can show a real reason instead
    /// of a generic revert. Note this does NOT gate withdrawals --
    /// emergencyWithdraw() works regardless of what this returns, and
    /// withdraw() only defers the reward rather than failing.
    /// Does not cover the per-block cooldown (which is transient and
    /// resolves on the next block) or per-user payout caps.
    function payoutHealth() external view returns (bool canPayNow, string memory reason) {
        if (!isWiredForMining())    return (false, "not registered as category-2 distributor");
        if (paused())               return (false, "mining contract paused");
        if (pool.paused())          return (false, "RewardPool paused");
        if (pool.emissionStopped()) return (false, "emission stopped");
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (miningAvail == 0)       return (false, "daily mining budget exhausted");
        return (true, "ready");
    }

    function tierCapacityLp(TierId tierId) external view returns (uint256) {
        return tiers[tierId].capacityLp;
    }

    function tierLpToken(TierId tierId) external view returns (address) {
        return tiers[tierId].lpToken;
    }

    /// True if token is the LP token of ANY tier -- used by rescueToken
    /// to make sure depositor funds can never be swept out.
    function isProtectedToken(address token) public view returns (bool) {
        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            if (tiers[all[i]].lpToken == token) return true;
        }
        return false;
    }

    // ====================== ADMIN -- CONFIG ======================

    function setReferralContract(address _referral) external onlyOwner {
        require(_referral != address(0), "zero address");
        require(_referral.code.length > 0, "referral must be a contract");
        referralContract = IOSGLPReferral(_referral);
        emit ReferralContractUpdated(_referral);
    }

    /// FIX 4: assign or change a tier's LP token. Only allowed while the
    /// tier holds ZERO deposits -- otherwise existing depositors' balances
    /// would be denominated in a token the contract no longer transfers.
    function setTierLpToken(TierId tierId, address _lpToken) external onlyOwner {
        require(_lpToken.code.length > 0, "lpToken not contract");
        TierConfig storage t = tiers[tierId];
        require(t.totalDepositedLp == 0, "tier has deposits");
        t.lpToken = _lpToken;
        emit TierLpTokenUpdated(tierId, _lpToken);
    }

    /// Deactivating a tier automatically zeroes its weight, freeing that
    /// budget share for other tiers. Re-enabling does NOT restore weight.
    function updateTierConfig(
        TierId tierId, uint256 minDeposit, uint256 capacityLp, bool active
    ) external onlyOwner {
        _updateTierRewards(tierId);
        TierConfig storage t = tiers[tierId];
        require(capacityLp >= t.totalDepositedLp, "capacity below deposited amount");
        if (active) {
            require(t.lpToken != address(0), "set tier lpToken first");
        }
        t.minDeposit = minDeposit;
        t.capacityLp = capacityLp;
        t.active     = active;

        if (!active && t.tierWeightBps > 0) {
            totalTierWeightBps -= t.tierWeightBps;
            t.tierWeightBps = 0;
            emit TierWeightUpdated(tierId, 0, totalTierWeightBps);
        }

        emit TierConfigUpdated(tierId, minDeposit, capacityLp, active);
    }

    function setMiningShareBps(uint256 newBps) external onlyOwner {
        require(newBps <= maxShareBps, "exceeds maxShareBps");
        _settleAllActiveTiers();
        miningShareBps = newBps;
        emit MiningShareUpdated(newBps, msg.sender);
    }

    /// Rebalances each tier's slice of the total budget. Always validates
    /// the sum across all 5 tiers stays <= 100%, and settles every active
    /// tier at its OLD weight first.
    function setTierWeightBps(TierId tierId, uint256 newWeightBps) external onlyOwner {
        require(newWeightBps == 0 || tiers[tierId].active, "cannot weight an inactive tier");

        _settleAllActiveTiers();

        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        uint256 total = 0;
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            total += (all[i] == tierId) ? newWeightBps : tiers[all[i]].tierWeightBps;
        }
        require(total <= BPS_DENOM, "total tier weights exceed 100%");

        tiers[tierId].tierWeightBps = newWeightBps;
        totalTierWeightBps = total;
        emit TierWeightUpdated(tierId, newWeightBps, total);
    }

    function setMaxShareBps(uint256 newMax) external onlyOwner {
        require(newMax <= ABSOLUTE_MAX_SHARE_BPS, "exceeds absolute max");
        maxShareBps = newMax;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover tokens sent here by mistake. Can never touch ANY tier's
    /// LP token -- deposited LP belongs to depositors.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(!isProtectedToken(token), "cannot rescue a tier LP token");
        require(to != address(0) && amount > 0, "bad args");
        IERC20(token).safeTransfer(to, amount);
    }

    function version() external pure returns (string memory) {
        return "OSGLPMining v6";
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {KairosPool} from "./KairosPool.sol";
import {MaturityCalendar} from "./libraries/MaturityCalendar.sol";

/// @title KairosFactory
/// @notice Deploys and registers Kairos pools at deterministic addresses.
/// @dev Uses the transient-parameters pattern so the pool's creation code is constant and every
///      address is derivable off-chain from `(token0, token1, baseFee, theta, maturityPeriod)`.
contract KairosFactory {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Parameters {
        address token0;
        address token1;
        uint256 baseFee;
        uint256 theta;
        uint32 maturityPeriod;
        bool blockScopedPremium;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint256 baseFee,
        uint256 theta,
        uint32 maturityPeriod,
        bool blockScopedPremium,
        address pool
    );
    event ConfigEnabled(uint256 baseFee, uint256 theta, uint32 maturityPeriod, bool blockScopedPremium);
    event OwnerChanged(address indexed from, address indexed to);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error IdenticalTokens();
    error ZeroAddress();
    error PoolExists();
    error ConfigNotEnabled();
    error InvalidConfig();
    error NotOwner();

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Read by {KairosPool} during construction.
    Parameters public parameters;

    address public owner;

    /// @notice token0 => token1 => configId => pool
    mapping(address => mapping(address => mapping(bytes32 => address))) public getPool;

    /// @notice Configurations the factory will deploy.
    mapping(bytes32 configId => bool) public configEnabled;

    address[] public allPools;

    /*//////////////////////////////////////////////////////////////
                                 LIMITS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_BASE_FEE = 0.01e18; // 100 bps
    uint256 internal constant MAX_THETA = 8e18;
    uint32 internal constant MIN_MATURITY = 32 minutes; // 1_920s == 32 * 60
    uint32 internal constant MAX_MATURITY = 30 days; // 2_592_000s == 32 * 81_000

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        // Three reference configurations spanning the recapture/tracking trade-off.
        //   theta = 1e18  -> pool closes 1/2 of each gap per block, LPs retain ~33% of LVR
        //   theta = 3e18  -> pool closes 1/4 of each gap per block, LPs retain ~43% of LVR
        // Recapture is theta/(1+2*theta), which saturates at 50%; see docs/WHITEPAPER.md.
        // Maturity periods must divide evenly into `MaturityCalendar.BUCKETS` buckets; 2h/4h do.
        _enable(0.0005e18, 1e18, 2 hours, true); //  5 bps, balanced, block-scoped
        _enable(0.0005e18, 3e18, 2 hours, true); //  5 bps, aggressive recapture
        _enable(0.0005e18, 3e18, 2 hours, false); //  5 bps, aggressive recapture, swap-scoped
        _enable(0.0005e18, 6e18, 2 hours, false); //  5 bps, maximal recapture, swap-scoped
        _enable(0.003e18, 1e18, 4 hours, true); // 30 bps, long-tail pairs
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function configId(uint256 baseFee, uint256 theta, uint32 maturityPeriod, bool blockScopedPremium)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(baseFee, theta, maturityPeriod, blockScopedPremium));
    }

    /// @notice Deploys a pool for `tokenA`/`tokenB` under an enabled configuration.
    function createPool(
        address tokenA,
        address tokenB,
        uint256 baseFee,
        uint256 theta,
        uint32 maturityPeriod,
        bool blockScopedPremium
    ) external returns (address pool) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();

        bytes32 cfg = configId(baseFee, theta, maturityPeriod, blockScopedPremium);
        if (!configEnabled[cfg]) revert ConfigNotEnabled();
        if (getPool[token0][token1][cfg] != address(0)) revert PoolExists();

        parameters = Parameters(token0, token1, baseFee, theta, maturityPeriod, blockScopedPremium);
        pool = address(new KairosPool{salt: keccak256(abi.encode(token0, token1, cfg))}());
        delete parameters;

        getPool[token0][token1][cfg] = pool;
        allPools.push(pool);

        emit PoolCreated(token0, token1, baseFee, theta, maturityPeriod, blockScopedPremium, pool);
    }

    /// @notice Enables a new configuration. Bounds are enforced so no pool can be deployed with a
    ///         maturity period that breaks the calendar's bucket arithmetic.
    function enableConfig(uint256 baseFee, uint256 theta, uint32 maturityPeriod, bool blockScopedPremium)
        external
        onlyOwner
    {
        _enable(baseFee, theta, maturityPeriod, blockScopedPremium);
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _enable(uint256 baseFee, uint256 theta, uint32 maturityPeriod, bool blockScopedPremium) internal {
        if (baseFee > MAX_BASE_FEE) revert InvalidConfig();
        if (theta == 0 || theta > MAX_THETA) revert InvalidConfig();
        if (maturityPeriod < MIN_MATURITY || maturityPeriod > MAX_MATURITY) revert InvalidConfig();
        // The calendar splits one maturity period into exactly `BUCKETS` buckets.
        if (maturityPeriod % MaturityCalendar.BUCKETS != 0) revert InvalidConfig();

        configEnabled[configId(baseFee, theta, maturityPeriod, blockScopedPremium)] = true;
        emit ConfigEnabled(baseFee, theta, maturityPeriod, blockScopedPremium);
    }
}

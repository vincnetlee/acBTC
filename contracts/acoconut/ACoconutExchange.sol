// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.6.8;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./IPoolToken.sol";

/**
 * @notice ACoconut exchange.
 */
contract ACoconutExchange {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /**
     * @dev Token exchanged between two underlying tokens.
     */
    event TokenExchanged(address indexed buyer, address indexed tokenSold, address indexed tokenBought, uint256 amountSold, uint256 amountBought, uint256 fee);
    /**
     * @dev New pool token is minted.
     */
    event Minted(address indexed provider, uint256[] amounts, uint256 oldSupply, uint256 newSupply, uint256 fee);
    /**
     * @dev Pool token is redeemed.
     */
    event Redeemed(address indexed provider, uint256[] amounts, uint256 oldSupply, uint256 newSupply, uint256 fee);

    uint256 public constant feeDenominator = 10 ** 10;
    address[] public coins;
    uint256[] public precisions; // 10 ** (18 - token decimals)
    uint256[] public balances;  // Converted to 10 ** 18
    uint256 public fee;     // Mint/Swap fee * 10**10
    uint256 public redemptionFee; // Redemption fee * 10**10
    address public feeReceiver;
    address public governance;
    address public poolToken;

    uint256 public initialA;
    uint256 public futureA;
    uint256 public initialATimestamp;
    uint256 public futureATimestamp;

    bool public paused;
    bool public terminated;

    constructor(address[] memory _coins, uint256[] memory _precisions, address _poolToken, address _feeReceiver, uint256 _A, uint256 _fee, uint256 _redemptionFee) public {
        require(_coins.length == _precisions.length, "ACoconutSwap: input mismatch");
        for (uint256 i = 0; i < _coins.length; i++) {
            require(_coins[i] != address(0x0), "ACoconutSwap: token not set");
            require(_precisions[i] != 0, "ACoconutSwap: precision not set");
            balances.push(0);
        }
        require(_poolToken != address(0x0), "ACoconutSwap: pool token not set");
        require(_feeReceiver != address(0x0), "ACoconutSwap: fee receiver not set");
        coins = _coins;
        poolToken = _poolToken;
        feeReceiver = _feeReceiver;
        initialA = _A;
        futureA = _A;
        fee = _fee;
        redemptionFee = _redemptionFee;
    }

    /**
     * @dev Handles ramping up or down of A
     */
    function getA() public view returns (uint256) {
        uint256 t1 = futureATimestamp;
        uint256 a1 = futureA;

        if (block.timestamp < t1) {
            uint256 t0 = initialATimestamp;
            uint256 a0 = initialA;

            if (a1 > a0) {
                // a0 + (a1 - a0) * (block.timestamp - t0) / (t1 - t0)
                return a0.add(a1.sub(a0).mul(block.timestamp.sub(t0)).div(t1.sub(t0)));
            } else {
                // a0 - (a0 - a1) * (block.timestamp - t0) / (t1 - t0)
                return a0.sub(a0.sub(a1).mul(block.timestamp.sub(t0)).div(t1.sub(t0)));
            }
        } else {
            return a1;
        }
    }

    /**
     * @dev Computes D given token balances.
     * @param _balances Normalized balance of each token.
     * @param _A Amplification coefficient from getA()
     */
    function _getD(uint256[] memory _balances, uint256 _A) internal pure returns (uint256) {
        uint256 sum = 0;
        uint256 i = 0;
        for (i = 0; i < _balances.length; i++) {
            sum = sum.add(_balances[i]);
        }
        if (sum == 0)   return 0;

        uint256 prevD = 0;
        uint256 D = sum;
        uint256 Ann = _A * _balances.length;
        for (i = 0; i < 255; i++) {
            uint256 pD = D;
            for (i = 0; i < _balances.length; i++) {
                pD = pD.mul(D).div(_balances[i].mul(_balances.length));
            }
            prevD = D;
            D = Ann.mul(sum).add(pD.mul(_balances.length)).mul(D).div(Ann.sub(1).mul(D).add(_balances.length.add(1).mul(pD)));
            if (D > prevD) {
                if (D - prevD <= 1) break;
            } else {
                if (prevD - D <= 1) break;
            }
        }

        return D;
    }

    /**
     * @dev Computes token balance given D.
     * @param _balances Converted balance of each token except token with index _j.
     * @param _j Index of the token to calculate balance.
     * @param _D The target D value.
     * @param _A Amplification coeffient.
     * @return Converted balance of the token with index _j.
     */
    function _getY(uint256[] memory _balances, uint256 _j, uint256 _D, uint256 _A) internal pure returns (uint256) {
        uint256 c = _D;
        uint256 S_ = 0;
        uint256 Ann = _A * _balances.length;
        uint256 i = 0;
        for (i = 0; i < _balances.length; i++) {
            if (i == _j) continue;
            S_ = S_.add(_balances[i]);
            // c = c * D / (_x * N)
            c = c.mul(_D).div(_balances[i].mul(_balances.length));
        }
        // c = c * D / (Ann * N)
        c = c.mul(_D).div(Ann.mul(_balances.length));
        // b = S_ + D / Ann
        uint256 b = S_.add(_D.div(Ann));
        uint256 prevY = 0;
        uint256 y = _D;

        // 255 since the result is 256 digits
        for (i = 0; i < 255; i++) {
            prevY = y;
            // y = (y * y + c) / (2 * y + b - D)
            y = y.mul(y).add(c).div(y.mul(2).add(b).sub(_D));
            if (y > prevY) {
                if (y - prevY <= 1) break;
            } else {
                if (prevY - y <= 1) break;
            }
        }

        return y;
    }

    /**
     * @dev Compute the amount of pool token that can be minted.
     * @param _amounts Unconverted token balances.
     * @return The amount of pool token minted.
     */
    function getMintAmount(uint256[] memory _amounts) public view returns (uint256) {
        require(_amounts.length == balances.length, "ACoconutSwap: length not match");
        uint256[] memory _balances = balances;
        uint256 A = getA();
        uint256 oldD = _getD(_balances, A);
        for (uint256 i = 0; i < _balances.length; i++) {
            // balance = balance + amount * precision
            _balances[i] = _balances[i].add(_amounts[i].mul(precisions[i]));
        }
        uint256 newD = _getD(_balances, A);

        // newD should be bigger than or equal to oldD
        return newD.sub(oldD);
    }

    /**
     * @dev Compute the amount of pool token that needs to be burned.
     * @param _amounts Unconverted token balances.
     * @return The amount of pool token that needs to be burned.
     */
    function getRedemptionAmount(uint256[] memory _amounts) public view returns (uint256) {
        require(_amounts.length == balances.length, "ACoconutSwap: length not match");
        uint256[] memory _balances = balances;
        uint256 A = getA();
        uint256 oldD = _getD(_balances, A);
        for (uint256 i = 0; i < _balances.length; i++) {
            // balance = balance + amount * precision
            _balances[i] = _balances[i].sub(_amounts[i].mul(precisions[i]));
        }
        uint256 newD = _getD(_balances, A);

        // newD should be smaller than or equal to oldD
        return oldD.sub(newD);
    }

    /**
     * @dev Mints new pool token.
     * @param _amounts Unconverted token balances used to mint pool token.
     * @return Amount of pool token minted.
     */
    function mint(uint256[] memory _amounts) public returns (uint256) {
        uint256[] memory _balances = balances;
        require(!paused && !terminated, "ACoconutSwap: paused");
        require(_balances.length == _amounts.length, "ACoconutExchange: invalid amounts");
        uint256 A = getA();
        uint256 oldD = _getD(_balances, A);
        uint256 i = 0;

        for (i = 0; i < _balances.length; i++) {
            if (oldD == 0) {
                // Initial deposit rquires all tokens provided!
                require(_amounts[i] > 0, "ACoconutSwap: zero amount");
                _balances[i] = _balances[i].add(_amounts[i].mul(precisions[i]));
            }
        }
        uint256 newD = _getD(_balances, A);
        uint256 mintAmount = newD.sub(oldD);
        uint256 feeAmount;
        uint256 _fee = fee;
        if (_fee > 0) {
            feeAmount = mintAmount.mul(_fee).div(feeDenominator);
            IPoolToken(poolToken).mint(feeReceiver, feeAmount);
            mintAmount = mintAmount.sub(feeAmount);
        }
        IPoolToken(poolToken).mint(msg.sender, mintAmount);

        // Transfer tokens into the swap
        for (i = 0; i < _amounts.length; i++) {
            if (_amounts[i] == 0)    continue;
            IERC20(coins[i]).safeTransferFrom(msg.sender, address(this), _amounts[i]);
        }

        emit Minted(msg.sender, _amounts, oldD, newD, feeAmount);

        return mintAmount;
    }

    /**
     * @dev Computes the output amount after the exchange.
     * @param _i Token index to exchange in.
     * @param _j Token index to exchange out.
     * @param _dx Unconverted amount of token _i to exchange in.
     * @return Unconverted amount of token _j to exchange out.
     */
    function getDy(uint256 _i, uint256 _j, uint256 _dx) external view returns (uint256) {
        uint256[] memory _balances = balances;
        uint256 A = getA();
        uint256 D = _getD(_balances, A);
        _balances[_i] = _balances[_i].add(_dx.mul(precisions[_i]));
        uint256 y = _getY(_balances, _j, D, A);

        if (fee > 0) {
            y = y.sub(y.mul(fee).div(feeDenominator));
        }

        return _balances[_j].sub(y).sub(1).div(precisions[_j]);
    }

    /**
     * @dev Exchange between two underlying tokens.
     * @param _i Token index to exchange in.
     * @param _j Token index to exchange out.
     * @param _dx Unconverted amount of token _i to exchange in.
     * @param _minDy Minimum token _j to exchange out in converted balance.
     * @return Unconverted amount of token _j to exchange out.
     */
    function exchange(uint256 _i, uint256 _j, uint256 _dx, uint256 _minDy) external returns (uint256) {

    }
}
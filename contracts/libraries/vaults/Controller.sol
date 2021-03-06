// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/IERC20Mintable.sol";
import "../interfaces/IController.sol";
import "./RewardedVault.sol";

/**
 * @notice Controller for vaults.
 */
contract Controller is IController {
    using SafeMath for uint256;

    address public override rewardToken;
    address public governance;
    address public reserve;
    uint256 public numVaults;
    mapping(uint256 => address) public vaults;

    constructor(address _rewardToken) public {
        require(_rewardToken != address(0x0), "reward token not set");
        
        governance = msg.sender;
        reserve = msg.sender;
        rewardToken = _rewardToken;
    }

    /**
     * @dev Updates the govenance address.
     */
    function setGovernance(address _governance) public {
        require(msg.sender == governance, "not governance");
        governance = _governance;
    }

    /**
     * @dev Updates the rewards token.
     */
    function setRewardToken(address _rewardToken) public {
        require(msg.sender == governance, "not governance");
        require(_rewardToken != address(0x0), "reward token not set");

        rewardToken = _rewardToken;
    }

    /**
     * @dev Updates the reserve address.
     */
    function setReserve(address _reserve) public {
        require(msg.sender == governance, "not governance");
        require(_reserve != address(0x0), "reserve not set");

        reserve = _reserve;
    }

    /**
     * @dev Add a new vault to the controller.
     */
    function addVault(address _vault) public {
        require(msg.sender == governance, "not governance");
        require(_vault != address(0x0), "vault not set");

        vaults[numVaults++] = _vault;
    }

    /**
     * @dev Add new rewards to a rewarded vault.
     * @param _vaultId ID of the vault to have reward.
     * @param _rewardAmount Amount of the reward token to add.
     */
    function addRewards(uint256 _vaultId, uint256 _rewardAmount) public {
        require(msg.sender == governance, "not governance");
        require(vaults[_vaultId] != address(0x0), "vault not exist");
        require(_rewardAmount > 0, "zero amount");

        address vault = vaults[_vaultId];
        IERC20Mintable(rewardToken).mint(vault, _rewardAmount);
        // Mint 40% of tokens to governance.
        IERC20Mintable(rewardToken).mint(reserve, _rewardAmount.mul(2).div(5));
        RewardedVault(vault).notifyRewardAmount(_rewardAmount);
    }

    /**
     * @dev Helpher function to earn in the vault. Anyone can call this method as
     * earn() in vault is public!
     * @param _vaultId ID of the vault to earn.
     */
    function earn(uint256 _vaultId) public {
        require(vaults[_vaultId] != address(0x0), "vault not exist");
        RewardedVault(vaults[_vaultId]).earn();
    }

    /**
     * @dev Helper function to earn in all vaults. Anyone can call this method as
     * earn() in vault is public!
     */
    function earnAll() public {
        for (uint256 i = 0; i < numVaults; i++) {
            RewardedVault(vaults[i]).earn();
        }
    }
}
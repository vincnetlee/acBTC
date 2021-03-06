const { BN, expectRevert, time } = require('@openzeppelin/test-helpers');
const assert = require('assert');
const RenCrv = artifacts.require("MockRenCrv");
const ACoconut = artifacts.require("MockWBTC");
const Controller = artifacts.require("Controller");
const Account = artifacts.require("Account");
const AccountFactory = artifacts.require("AccountFactory");
const ACoconutVault = artifacts.require("ACoconutVault");
const StakingApplication = artifacts.require("StakingApplication");

const assertAlmostEqual = function(expectedOrig, actualOrig) {
    const _1e18 = new BN('10').pow(new BN('18'));
    const expected = new BN(expectedOrig).div(_1e18).toNumber();
    const actual = new BN(actualOrig).div(_1e18).toNumber();

    assert.ok(Math.abs(expected - actual) <= 2, `Expected ${expected}, actual ${actual}`);
}

contract('StakingApplication', async ([owner, user1, user2]) => {
    let renCrv;
    let aCoconut;
    let aCoconutVault;
    let controller;
    let accountFactory;
    let stakingApplication;
    beforeEach(async () => {
        renCrv = await RenCrv.new();
        aCoconut = await ACoconut.new();
        controller = await Controller.new(aCoconut.address);
        const migrationDue = (await time.latest()).toNumber() + 3600;
        aCoconutVault = await ACoconutVault.new("ACoconut BTC Vault Token", "acBTCv", controller.address, renCrv.address, migrationDue);
        const account = await Account.new();
        accountFactory = await AccountFactory.new(account.address);
        stakingApplication = await StakingApplication.new();
        await stakingApplication.initialize(controller.address);
    });
    it("should initialize parameters", async () => {
        assert.strictEqual(await stakingApplication.governance(), owner);
        assert.strictEqual(await stakingApplication.controller(), controller.address);
    });
    it("should set governance", async () => {
        assert.strictEqual(await stakingApplication.governance(), owner);
        await expectRevert(stakingApplication.setGovernance(user2, {from: user1}), "not governance");
        await stakingApplication.setGovernance(user1);
        assert.strictEqual(await stakingApplication.governance(), user1);
    });
    it("should set controller", async () => {
        assert.strictEqual(await stakingApplication.controller(), controller.address);
        await expectRevert(stakingApplication.setController(user2, {from: user1}), "not governance");
        await stakingApplication.setController(user1);
        assert.strictEqual(await stakingApplication.controller(), user1);
    });
    it("should stake on valid vault", async () => {
        await accountFactory.createAccount([stakingApplication.address], {from: owner});
        const account = await accountFactory.accounts(owner);
        await expectRevert(stakingApplication.stake(account, 0, 200, false), "no vault");
        await expectRevert(stakingApplication.unstake(account, 0, 200, false), "no vault");
        await expectRevert(stakingApplication.claimRewards(account, 0), "no vault");
    });
    it("should have account to stake", async () => {
        await controller.addVault(aCoconutVault.address);
        await renCrv.mint(user1, 2000);
        await accountFactory.createAccount([stakingApplication.address], {from: user2});
        const account1 = await accountFactory.accounts(user2);
        await expectRevert(stakingApplication.stake(account1, 0, 1000, false, {from: user1}), "not owner");
        await accountFactory.createAccount([], {from: user1});
        const account2 = await accountFactory.accounts(user1);
        await expectRevert(stakingApplication.stake(account2, 0, 1000, false, {from: user1}), "not operator");
    });
    it("should be able to stake and unstake", async () => {
        await controller.addVault(aCoconutVault.address);
        await accountFactory.createAccount([stakingApplication.address], {from: user1});
        const account = await accountFactory.accounts(user1);
        await renCrv.mint(account, 2000);
        assert.strictEqual((await renCrv.balanceOf(account)).toNumber(), 2000);

        await stakingApplication.stake(account, 0, 800, false, {from: user1});
        assert.strictEqual((await renCrv.balanceOf(account)).toNumber(), 1200);
        assert.strictEqual((await aCoconutVault.balanceOf(account)).toNumber(), 800);
        assert.strictEqual((await stakingApplication.getStakeBalance(account, 0)).toNumber(), 800);
        assert.strictEqual((await stakingApplication.getVaultBalance(0)).toNumber(), 800);

        await stakingApplication.unstake(account, 0, 300, false, {from: user1});
        assert.strictEqual((await renCrv.balanceOf(account)).toNumber(), 1500);
        assert.strictEqual((await aCoconutVault.balanceOf(account)).toNumber(), 500);
        assert.strictEqual((await stakingApplication.getStakeBalance(account, 0)).toNumber(), 500);
        assert.strictEqual((await stakingApplication.getVaultBalance(0)).toNumber(), 500);
    });
    it("should be able to get rewards", async () => {
        await controller.addVault(aCoconutVault.address);
        await accountFactory.createAccount([stakingApplication.address], {from: user1});
        const account = await accountFactory.accounts(user1);
        await renCrv.mint(account, 2000);
        assert.strictEqual((await renCrv.balanceOf(account)).toNumber(), 2000);

        await stakingApplication.stake(account, 0, 800, false, {from: user1});
        assert.strictEqual((await stakingApplication.getUnclaimedReward(account, 0)).toNumber(), 0);
        await aCoconut.mint(owner, web3.utils.toWei('40000'));
        await aCoconut.approve(aCoconutVault.address, web3.utils.toWei('40000'));
        await controller.addRewards(0, web3.utils.toWei('40000'));

        // After 7 days, user1 should get all the rewards!
        assert.strictEqual((await aCoconut.balanceOf(account)).toNumber(), 0);
        await time.increase(3600 * 24 * 8);
        assertAlmostEqual(await stakingApplication.getUnclaimedReward(account, 0), web3.utils.toWei('40000'));
        assert.strictEqual((await stakingApplication.getClaimedReward(account, 0)).toNumber(), 0);
        await stakingApplication.claimRewards(account, 0, {from: user1});
        assert.strictEqual((await stakingApplication.getUnclaimedReward(account, 0)).toNumber(), 0);
        assertAlmostEqual(await stakingApplication.getClaimedReward(account, 0), web3.utils.toWei('40000'));
        assertAlmostEqual(await aCoconut.balanceOf(account), web3.utils.toWei('40000'));
    });
});
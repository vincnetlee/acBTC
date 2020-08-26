const { expectRevert } = require('@openzeppelin/test-helpers');
const BasketManagerProxy = artifacts.require("BasketManagerProxy");
const BasketCoreProxy = artifacts.require("BasketCoreProxy");
const BasketManager = artifacts.require("BasketManager");
const BasketCore = artifacts.require("BasketCore");
const AcBTC = artifacts.require("AcBTC");
const ERC20 = artifacts.require("MockToken");
const assert = require('assert');

let basketManager;
let basketCore;
let basketToken;

contract("BasketManager", ([owner, proxyAdmin, user1, user2]) => {
    before(async () => {
        const basketManagerProxy = await BasketManagerProxy.deployed();
        basketManager = await BasketManager.at(basketManagerProxy.address);
        const basketCoreProxy = await BasketCoreProxy.deployed();
        basketCore = await BasketCore.at(basketCoreProxy.address);
        basketToken = await AcBTC.deployed();
    });
    it('should allow add new token by owner', async () => {
        const token = await ERC20.new("Test token", "test");
        await basketManager.addToken(token.address, {from: owner});
        const tokens = await basketManager.getTokens();
        assert.deepEqual(tokens, [token.address]);
        const tokenStatus = await basketManager.getTokenStatus(tokens[0]);
        assert.equal(tokenStatus.toNumber(), 1);
    });
    it('should not allow add new token by other user', async () => {
        const token = await ERC20.new("Test token", "test");
        await expectRevert(basketManager.addToken(token.address, {from: user1}), "Ownable: caller is not the owner");
    });
    it('should allow mint new tokens', async () => {
        const token = await ERC20.new("Test token", "test");
        await basketManager.addToken(token.address, {from: owner});
        await token.mint(10000, {from: user1});
        await token.approve(basketCore.address, 10000, {from: user1});
        const prevBalance = await basketToken.balanceOf(user1);
        const prevCoreBalance = await basketCore.getTokenBalance(token.address);
        await basketManager.mint([token.address], [10000], {from: user1});
        const currBalance = await basketToken.balanceOf(user1);
        const currCoreBalance = await basketCore.getTokenBalance(token.address);
        assert.equal(currBalance - prevBalance, 10000);
        assert.equal(currCoreBalance - prevCoreBalance, 10000);

    });
    it('should allow redeem basket tokens', async () => {
        const token1 = await ERC20.new("Test token 1", "test1");
        await basketManager.addToken(token1.address, {from: owner});
        await token1.mint(10000, {from: user1});
        await token1.approve(basketCore.address, 10000, {from: user1});

        const token2 = await ERC20.new("Test token 2", "test2");
        await basketManager.addToken(token2.address, {from: owner});
        await token2.mint(10000, {from: user1});
        await token2.approve(basketCore.address, 10000, {from: user1});

        const prevBalance = await basketToken.balanceOf(user1);
        await basketManager.mint([token1.address], [10000], {from: user1});
        await basketManager.mint([token2.address], [5000], {from: user1});
        const currBalance = await basketToken.balanceOf(user1);
        assert.equal(currBalance - prevBalance, 15000);

        // Transfer acBTC to user2
        await basketToken.transfer(user2, 12000, {from: user1});
        await basketToken.approve(basketCore.address, 9000, {from: user2});
        await basketManager.redeem(9000, {from: user2});
    });
});
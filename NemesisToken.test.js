const { expect } = require("chai");

describe("NemesisToken", function () {
  it("Should deploy and assign total supply to owner", async function () {
    const [owner] = await ethers.getSigners();
    const Token = await ethers.getContractFactory("NemesisToken");
    const token = await Token.deploy();
    const totalSupply = await token.totalSupply();

    expect(await token.balanceOf(owner.address)).to.equal(totalSupply);
  });
});

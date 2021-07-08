const HSWToken = artifacts.require("HSWToken")

module.exports = async function(deployer) {
  await deployer.deploy(HSWToken);
};

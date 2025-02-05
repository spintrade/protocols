const hre = require("hardhat");
const ethers = hre.ethers;
import { newWalletImpl, newWalletFactoryContract } from "../test/commons";
import { signCreateWallet } from "../test/helper/signatureUtils";
import BN = require("bn.js");

async function newWallet() {
  const smartWalletAddress = "0x19F3338C71a16696D27B68DEF0d2fB27Aa4b8807";
  const walletFactoryAddress = "0x44B74caF7CB28cC243EaA9D1d1b3eCb2Ddc2C9f1";

  const ownerAccount = (await ethers.getSigners())[0];
  const ownerAddr = await ownerAccount.getAddress();
  const fakeGuardian1 = "0x" + "12".repeat(20);
  const salt = 1;
  const signature = signCreateWallet(
    walletFactoryAddress,
    ownerAddr,
    [fakeGuardian1],
    new BN(0),
    ethers.constants.AddressZero,
    ethers.constants.AddressZero,
    ethers.constants.AddressZero,
    new BN(0),
    salt
  );
  const walletConfig: any = {
    owner: ownerAddr,
    guardians: [fakeGuardian1],
    quota: 0,
    inheritor: ethers.constants.AddressZero,
    feeRecipient: ethers.constants.AddressZero,
    feeToken: ethers.constants.AddressZero,
    feeAmount: 0,
    signature: Buffer.from(signature.txSignature.slice(2), "hex")
  };

  const walletFactory = await (
    await ethers.getContractFactory("WalletFactory")
  ).attach(walletFactoryAddress);

  const walletAddrComputed = await walletFactory.computeWalletAddress(
    ownerAddr,
    salt
  );
  console.log("walletAddrcomputed:", walletAddrComputed);

  const tx = await walletFactory.createWallet(walletConfig, salt, {
    gasLimit: 10000000
  });
  console.log("tx:", tx);
  const receipt = await tx.wait();
  console.log("receipt:", receipt);
}

async function newWalletFactory() {
  const walletFactory = await newWalletFactoryContract();
  console.log("walletFactory:", walletFactory.address);
}

// run with: npx hardhat run --network arbitrum scripts/deploy-arbitrum.ts
async function main() {
  // We get the contract to deploy
  // const TestTargetContract = await ethers.getContractFactory("TestTargetContract");
  // const testTargetContract = await TestTargetContract.deploy();
  // console.log("Greeter deployed to:", testTargetContract);

  // const walletImpl = await newWalletImpl();
  // console.log("walletImpl address:", walletImpl.address);
  // await newWalletFactory();

  await newWallet();
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

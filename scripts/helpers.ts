import fs from "fs";

import hre, { ethers } from "hardhat";
import { BaseContract, ContractTransaction, Signer } from "ethers";
import { ProxyAdmin } from "../typechain-types";

export = {
  getDeploySigner: async (): Promise<Signer> => {
    const ethersSigners = await Promise.all(await ethers.getSigners());
    return ethersSigners[0];
  },
  waitForDeploy: async (contract: BaseContract): Promise<BaseContract> => {
    var tx: ContractTransaction = contract.deployTransaction
    console.log('deploy contract', contract.address, 'at', tx.hash, 'waiting...')
    await tx.wait(1)
    console.log('deploy contract', contract.address, 'at', tx.hash, 'confirmed')
    return contract
  },
  waitForTx: async (tx: ContractTransaction) => {
    console.log('contract call method at', tx.hash, 'waiting...')
    await tx.wait(1)
    console.log('contract call method at', tx.hash, 'confirmed')
  },
  sleep: (ms: number) => {
    return new Promise(resolve => setTimeout(resolve, ms));
  },
  verifyContract: async (deployData: DeployData, network: string, address: string, constructorArguments: any, libraries: any, contract: string) => {
    if (network != 'local') {
      var verified = deployData.VerifiedContracts[address]
      if (verified == undefined || verified == false) {
        try {
          await hre.run("verify:verify", {
            address: address,
            constructorArguments: constructorArguments,
            libraries: libraries,
            contract: contract,
          })
        } catch (ex) {
          var err = '' + ex
          if (!err.includes('Already Verified')) {
            throw ex
          }
          console.log('Already verified contract address on Etherscan.')
          console.log('https://testnet.arbiscan.io//address/' + address + '#code')
        }
        deployData.VerifiedContracts[address] = true
        let fileName = process.cwd() + '/scripts/address/deployed_' + network + '.json';
        await fs.writeFileSync(fileName, JSON.stringify(deployData))
      }
    }
  },
  upgradeContract: async (proxyAdmin: ProxyAdmin, address: string, implAddress: string) => {
    if ((await proxyAdmin.getProxyImplementation(address)) != implAddress) {
      var tx = await proxyAdmin.upgrade(address, implAddress)
      console.log('proxyAdmin.upgrade at', address, implAddress, tx.hash, 'waiting...')
      await tx.wait(1)
      console.log('proxyAdmin.upgrade at', address, implAddress, tx.hash, 'confirmed')
    }
  },
}
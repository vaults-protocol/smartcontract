# npm run build

npx hardhat run deployments/migrate_1Contracts.ts --network arbitrumDev --no-compile
npx hardhat run deployments/migrate_2Init_Config.ts --network arbitrumDev --no-compile
npx hardhat run deployments/migrate_3Init_Token_All.ts --network arbitrumDev --no-compile
npx hardhat run deployments/migrate_4AddLiquidity.ts --network arbitrumDev --no-compile

# npx hardhat run deployments/19_migrate_Console.ts --network arbitrumDev --no-compile
# npx hardhat run deployments/20_migrate_Test.ts --network arbitrumDev --no-compile
# npx hardhat run deployments/22_migrate_Faucet.ts --network arbitrumDev --no-compile



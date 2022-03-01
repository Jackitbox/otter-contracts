const { ethers } = require('hardhat')

const investmentAddress = '0x07DB6BFbD71E9DE0AfF3ab3eAe4CBC7B13EEF952'
const investmentPid = 1 // usdc/mai
const curveDapDepositor = '0x5ab5c56b9db92ba45a0b46a207286cd83c15c939'
const curvePool = '0x447646e84498552e62eCF097Cc305eaBFFF09308'
const idxMAI = 0
const idxUSDC = 2

const USDCMAI = '0xa5e0829caced8ffdd4de3c43696c57f7d7a678ff'
const dQMVT = '0x649aa6e6b6194250c077df4fb37c23ee6c098513'
const dQUICK = '0xf28164a485b0b2c90639e47b0f377b4a438a16b1'
const MAI = '0xa3fa99a148fa48d14ed51d610c367c61876997f1'
const USDC = '0x2791bca1f2de4661ed88a30c99a7a9449aa84174'
const zeroAddress = '0x0000000000000000000000000000000000000000'

const treasuryAddress = '0x8ce47D56EAa1299d3e06FF3E04637449fFb01C9C'
const Treasury = await ethers.getContractFactory('OtterTreasury')
const treasury = Treasury.attach(treasuryAddress)

const deployer = await ethers.getSigner()
const daoAddress = '0x929a27c46041196e1a49c7b459d63ec9a20cd879'
await (
  await deployer.sendTransaction({
    to: daoAddress,
    value: ethers.utils.parseEther('0.5'),
  })
).wait()
await hre.network.provider.request({
  method: 'hardhat_impersonateAccount',
  params: [daoAddress],
})
const dao = await ethers.getSigner(daoAddress)

const kingAddress = '0x63B0fB7FE68342aFad3D63eF743DE4A74CDF462B'
await hre.network.provider.request({
  method: 'hardhat_impersonateAccount',
  params: [kingAddress],
})
const king = await ethers.getSigner(kingAddress)

const INVESTMENT = await ethers.getContractFactory('OtterQiDAOInvestment')
const investment = await INVESTMENT.attach(investmentAddress)
const LEVERAGE = await ethers.getContractFactory('OtterQiDAOLeverage')
const leverage = await LEVERAGE.deploy(
  investmentAddress,
  investmentPid,
  curveDapDepositor,
  curvePool,
  idxMAI,
  idxUSDC,
  USDCMAI,
  dQMVT,
  dQUICK,
  MAI,
  USDC,
  treasuryAddress,
  daoAddress
)
await (await investment.connect(king).pushManagement(leverage.address)).wait()
await (await leverage.pullContractManagement(investment.address)).wait()

const vault = await ethers.getContractAt('ERC721', dQMVT)
await (await leverage.createVault()).wait()
const vaultID = await vault.tokenOfOwnerByIndex(leverage.address, 0)
console.log(`vaultID = ${vaultID}`)

await treasury.connect(dao).queue('0', leverage.address)
await treasury.connect(dao).queue('3', leverage.address)
await treasury.connect(dao).queue('6', leverage.address)

async function mine(n, trunk = 50) {
  for (let i = 0; i < n; i += trunk) {
    console.log(`i = ${i}`)
    try {
      await Promise.all(
        Array(trunk)
          .fill(0)
          .map(async () => ethers.provider.send('evm_mine'))
      )
    } catch (err) {
      console.error(err)
    }
  }
}
await mine(86401)

await (await treasury.connect(dao).toggle('0', leverage.address, zeroAddress)).wait()
await (await treasury.connect(dao).toggle('3', leverage.address, zeroAddress)).wait()
await (await treasury.connect(dao).toggle('6', leverage.address, zeroAddress)).wait()

await (await leverage.depositCollateral(vaultID, ethers.utils.parseEther('0.1'))).wait()
await (await leverage.rebalance(vaultID, 300)).wait()
await leverage.collateralPercentage(vaultID)
await (await leverage.rebalance(vaultID, 310)).wait()
await leverage.collateralPercentage(vaultID)

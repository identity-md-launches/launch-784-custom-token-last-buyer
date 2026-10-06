import {
  createPublicClient, createWalletClient, custom, defineChain, encodeAbiParameters,
  encodeFunctionData, fallback, http, keccak256, parseAbi, parseAbiParameters,
  type Address, type Hex, type EIP1193Provider,
} from 'viem';
import deployment from './generated/deployment.json';
import parameters from './generated/network.json';
import verification from './generated/verification.json';
import { hookAbi, tokenAbi } from './generated/contracts';

export { hookAbi, tokenAbi, deployment };
export const network = parameters.network;
export const addresses = {
  win: deployment.contracts.find(c => c.name === 'WinToken')!.address as Address,
  hook: deployment.contracts.find(c => c.name === 'WinGameHook')!.address as Address,
  imd: network.pairToken.address as Address,
  router: network.uniswapV4.universalRouter as Address,
  permit2: network.uniswapV4.permit2 as Address,
  quoter: network.uniswapV4.quoter as Address,
  // Supplemental deployment record: parent project.md / task. Not in the two-contract ABI manifest.
  distributor: '0x9e515408cc0baa87d312315b8b0dee66bf0d9c2f' as Address,
};
export const chain = defineChain({
  id: network.chainId, name: network.name, nativeCurrency: network.nativeCurrency,
  rpcUrls: { default: { http: network.rpcUrls } },
  blockExplorers: { default: { name: 'Etherscan', url: network.explorer } },
});
export const client = createPublicClient({ chain, transport: fallback(
  network.rpcUrls.map(url => http(url, { timeout: 10_000, retryCount: 1 })),
) });
const currency0 = addresses.imd.toLowerCase() < addresses.win.toLowerCase() ? addresses.imd : addresses.win;
export const poolKey = {
  currency0, currency1: currency0 === addresses.imd ? addresses.win : addresses.imd,
  fee: deployment.manifest.pool.fee, tickSpacing: deployment.manifest.pool.tickSpacing, hooks: addresses.hook,
};
export const poolKeyParams = parseAbiParameters('(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)');
export const poolId = keccak256(encodeAbiParameters(poolKeyParams, [poolKey]));
export const routerAbi = parseAbi(['function execute(bytes commands, bytes[] inputs, uint256 deadline) payable']);
export const permitAbi = parseAbi([
  'function allowance(address owner,address token,address spender) view returns(uint160 amount,uint48 expiration,uint48 nonce)',
  'function approve(address token,address spender,uint160 amount,uint48 expiration)',
]);
export const quoterAbi = parseAbi([
  'function quoteExactInputSingle(((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) params) returns(uint256 amountOut,uint256 gasEstimate)',
]);
export type GameState = Awaited<ReturnType<typeof readGame>>['state'];
export type Winner = Awaited<ReturnType<typeof readWinners>>[number];
export async function readGame() {
  const block = await client.getBlock();
  const state = await client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'gameState', blockNumber: block.number });
  return { state, block: block.number, timestamp: block.timestamp, receivedAt: performance.now() };
}
export function readWinners() {
  return client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'pastWinners' });
}
export async function verifyDeployment() {
  if (await client.getChainId() !== chain.id) throw Error('The RPC returned a different network. Transactions are paused.');
  await Promise.all(verification.contracts.map(async item => {
    const code = await client.getCode({ address: item.address as Address });
    if (!code || keccak256(code) !== item.runtimeHash) throw Error(`Unable to verify ${item.name}. Transactions are paused.`);
  }));
  const [id, token, manager, imd] = await Promise.all([
    client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'poolId' }),
    client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'winToken' }),
    client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'poolManager' }),
    client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'imd' }),
  ]);
  if (id !== poolId || token.toLowerCase() !== addresses.win || manager.toLowerCase() !== network.uniswapV4.poolManager || imd.toLowerCase() !== addresses.imd)
    throw Error('Pool configuration does not match the deployment record. Transactions are paused.');
  return true;
}
export function buyerData(buyer: Address, mustLead: boolean) {
  return encodeAbiParameters(parseAbiParameters('address,bool'), [buyer, mustLead]);
}
export function direction(buy: boolean) { return buy === (poolKey.currency0 === addresses.imd); }
export const singleSwapParams = parseAbiParameters('((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint256 minHopPriceX36,bytes hookData)');
export function swapCall(buy: boolean, amount: bigint, minimumOut: bigint, buyer: Address, mustLead: boolean, deadline: bigint, hookData?: Hex) {
  if (amount <= 0n || amount >= 2n ** 128n || minimumOut <= 0n) throw Error('Enter a valid amount and get a fresh quote.');
  const swap = encodeAbiParameters(singleSwapParams, [{ poolKey, zeroForOne: direction(buy), amountIn: amount, amountOutMinimum: minimumOut, minHopPriceX36: 0n, hookData: hookData ?? buyerData(buyer, buy && mustLead) }]);
  const currencyAmount = parseAbiParameters('address,uint256');
  const inputs = [encodeAbiParameters(parseAbiParameters('bytes,bytes[]'), ['0x060c0f', [
    swap,
    encodeAbiParameters(currencyAmount, [buy ? addresses.imd : addresses.win, amount]),
    encodeAbiParameters(currencyAmount, [buy ? addresses.win : addresses.imd, minimumOut]),
  ]])];
  return { to: addresses.router, data: encodeFunctionData({ abi: routerAbi, functionName: 'execute', args: ['0x10', inputs, deadline] }) };
}
export function gameCall(action: 'settle' | 'claimPrize', account: Address) {
  return { to: addresses.hook, data: action === 'settle'
    ? encodeFunctionData({ abi: hookAbi, functionName: 'settle' })
    : encodeFunctionData({ abi: hookAbi, functionName: 'claimPrize', args: [account] }) };
}
export async function getQuote(buy: boolean, amount: bigint, buyer: Address, mustLead: boolean) {
  const { result } = await client.simulateContract({ address: addresses.quoter, abi: quoterAbi,
    functionName: 'quoteExactInputSingle', args: [{ poolKey, zeroForOne: direction(buy), exactAmount: amount, hookData: buyerData(buyer, buy && mustLead) }],
  });
  return result[0];
}
export async function switchNetwork(provider: EIP1193Provider) {
  try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: parameters.walletAddChain.chainId }] }); }
  catch (error) {
    if ((error as { code: number }).code !== 4902) throw error;
    await provider.request({ method: 'wallet_addEthereumChain', params: [parameters.walletAddChain] });
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: parameters.walletAddChain.chainId }] });
  }
}
export async function assertAccount(provider: EIP1193Provider, account: Address) {
  const wallet = createWalletClient({ chain, transport: custom(provider) });
  const [accounts, id] = await Promise.all([wallet.getAddresses(), wallet.getChainId()]);
  if (id !== chain.id) throw Error('Switch your wallet to Robinhood Chain and try again.');
  if (accounts[0]?.toLowerCase() !== account.toLowerCase()) throw Error('The wallet account changed. Review the trade again.');
  return wallet;
}
export async function sendCall(provider: EIP1193Provider, account: Address, call: { to: Address; data: Hex }, onHash: (hash: Hex) => void) {
  const wallet = await assertAccount(provider, account);
  await client.call({ ...call, account });
  const gas = await client.estimateGas({ ...call, account });
  await assertAccount(provider, account);
  const hash = await wallet.sendTransaction({ ...call, account, gas: gas * 12n / 10n });
  onHash(hash);
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (receipt.status !== 'success') throw Error('The transaction reverted. Refresh the quote and try again.');
  return receipt;
}

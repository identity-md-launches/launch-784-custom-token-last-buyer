import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import {
  createPublicClient, createWalletClient, decodeEventLog, encodeAbiParameters, encodeFunctionData,
  http, keccak256, parseAbiParameters, toHex, type Address, type Hex,
} from 'viem';
import { addresses, buyerData, chain, gameCall, hookAbi, network, permitAbi, swapCall, tokenAbi } from '../src/chain';

// This script creates and destroys its own local fork. Every write uses localhost only.
const port = 18545;
const fork = spawn('anvil', ['--fork-url', network.rpcUrls[0], '--port', String(port), '--chain-id', String(chain.id), '--silent'], { stdio: ['ignore', 'pipe', 'pipe'] });
let logs = '';
fork.stderr.on('data', data => { logs += data; });
const rpc = async (method: string, params: unknown[] = []) => {
  const response = await fetch(`http://127.0.0.1:${port}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const body = await response.json();
  if (body.error) throw Error(JSON.stringify(body.error));
  return body.result;
};
try {
  for (let i = 0; i < 100; i++) {
    try { await rpc('eth_chainId'); break; } catch { if (i === 99) throw Error(`Anvil did not start: ${logs}`); await new Promise(r => setTimeout(r, 200)); }
  }
  const local = createPublicClient({ chain, transport: http(`http://127.0.0.1:${port}`) });
  const wallet = createWalletClient({ chain, transport: http(`http://127.0.0.1:${port}`) });
  const [buyer, second] = await wallet.getAddresses();
  const forkBlock = await local.getBlockNumber();
  const read = (functionName: 'gameState') => local.readContract({ address: addresses.hook, abi: hookAbi, functionName });
  const balance = (token: Address, account: Address) => local.readContract({ address: token, abi: tokenAbi, functionName: 'balanceOf', args: [account] });
  const send = async (account: Address, call: { to: Address; data: Hex }) => {
    const gas = await local.estimateGas({ account, ...call });
    const hash = await wallet.sendTransaction({ account, ...call, gas: gas * 15n / 10n });
    const receipt = await local.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, 'success'); return receipt;
  };
  // Infer the real IMD balance mapping from a known holder; only edit storage on localhost.
  const manager = network.uniswapV4.poolManager as Address;
  const managerBalance = await balance(addresses.imd, manager);
  let balanceSlot: bigint | undefined;
  for (let slot = 0n; slot < 32n; slot++) {
    const index = keccak256(encodeAbiParameters(parseAbiParameters('address,uint256'), [manager, slot]));
    const value = await local.getStorageAt({ address: addresses.imd, slot: index });
    if (managerBalance > 0n && BigInt(value ?? '0x0') === managerBalance) { balanceSlot = slot; break; }
  }
  assert.notEqual(balanceSlot, undefined, 'Could not identify the IMD balance mapping');
  for (const account of [buyer, second]) {
    const index = keccak256(encodeAbiParameters(parseAbiParameters('address,uint256'), [account, balanceSlot!]));
    await rpc('anvil_setStorageAt', [addresses.imd, index, toHex(10n ** 26n, { size: 32 })]);
    assert.equal(await balance(addresses.imd, account), 10n ** 26n);
  }
  const approve = async (account: Address, token: Address, amount: bigint) => {
    await send(account, { to: token, data: encodeFunctionData({ abi: tokenAbi, functionName: 'approve', args: [addresses.permit2, amount] }) });
    const block = await local.getBlock();
    await send(account, { to: addresses.permit2, data: encodeFunctionData({ abi: permitAbi, functionName: 'approve', args: [token, addresses.router, amount, Number(block.timestamp + 86400n)] }) });
  };
  const buy = async (account: Address, data?: Hex) => {
    const state = await read('gameState');
    const input = state.minimumBuy * 2n;
    await approve(account, addresses.imd, input);
    const before = await balance(addresses.win, account);
    const timestamp = (await local.getBlock()).timestamp;
    const receipt = await send(account, swapCall(true, input, 1n, account, true, timestamp + 300n, data));
    assert.ok(await balance(addresses.win, account) > before, 'Buyer received no WIN');
    return receipt;
  };
  await buy(buyer);
  let state = await read('gameState');
  assert.equal(state.leader.toLowerCase(), buyer.toLowerCase(), 'Website buyer was not credited');
  // Empty hookData uses Universal Router.msgSender(); validates compatibility with other direct interfaces.
  await buy(second, '0x');
  state = await read('gameState');
  assert.equal(state.leader.toLowerCase(), second.toLowerCase(), 'Router caller was not credited');
  const deadline = state.deadline;
  const winToSell = (await balance(addresses.win, buyer)) / 10n;
  await approve(buyer, addresses.win, winToSell);
  const imdBeforeSell = await balance(addresses.imd, buyer);
  await send(buyer, swapCall(false, winToSell, 1n, buyer, false, (await local.getBlock()).timestamp + 300n));
  state = await read('gameState');
  assert.ok(await balance(addresses.imd, buyer) > imdBeforeSell);
  assert.equal(state.deadline, deadline, 'Sell changed the timer');
  assert.equal(state.leader.toLowerCase(), second.toLowerCase(), 'Sell changed the leader');
  const lowInput = state.minimumBuy / 2n;
  await approve(buyer, addresses.imd, lowInput);
  await assert.rejects(local.call({ account: buyer, ...swapCall(true, lowInput, 1n, buyer, true, (await local.getBlock()).timestamp + 300n) }), 'mustLead should reject dust');
  await rpc('evm_setNextBlockTimestamp', [Number(deadline) + 1]); await rpc('evm_mine');
  const pending = await read('gameState');
  assert.equal(pending.settleable, true); assert.equal(pending.pendingWinner.toLowerCase(), second.toLowerCase());
  const paidBefore = await balance(addresses.imd, second);
  await send(buyer, gameCall('settle', buyer));
  assert.equal(await balance(addresses.imd, second) - paidBefore, pending.pendingPrize, 'Settle payout incorrect');
  const winners = await local.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'pastWinners' });
  assert.equal(winners.at(-1)!.winner.toLowerCase(), second.toLowerCase());
  // A post-expiry buy creates a deferred prize, allowing real claimPrize validation.
  await buy(buyer);
  const active = await read('gameState');
  await rpc('evm_setNextBlockTimestamp', [Number(active.deadline) + 1]); await rpc('evm_mine');
  await buy(second);
  const unclaimed = await local.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'unclaimedPrize', args: [buyer] });
  assert.ok(unclaimed > 0n);
  const beforeClaim = await balance(addresses.imd, buyer);
  const claimReceipt = await send(buyer, gameCall('claimPrize', buyer));
  assert.equal(await balance(addresses.imd, buyer) - beforeClaim, unclaimed);
  assert.equal(await local.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'unclaimedPrize', args: [buyer] }), 0n);
  assert.ok(claimReceipt.logs.some(log => { try { return decodeEventLog({ abi: hookAbi, data: log.data, topics: log.topics }).eventName === 'PrizePaid'; } catch { return false; } }));
  if (process.env.WIN_BROWSER_CHECK === '1') {
    await buy(buyer);
    await rpc('evm_setNextBlockTimestamp', [Number((await read('gameState')).deadline) + 1]); await rpc('evm_mine');
    await buy(second);
    await rpc('evm_setNextBlockTimestamp', [Number((await read('gameState')).deadline) + 1]); await rpc('evm_mine');
    const { checkBrowser } = await import('./check-browser');
    await rpc('anvil_setIntervalMining', [1]);
    await checkBrowser(`http://127.0.0.1:${port}`, buyer);
  }
  console.log(JSON.stringify({ result: 'PASS', forkBlock: String(forkBlock), chainId: chain.id, checks: ['website buy credited', 'empty hookData router caller credited', 'sell output and unchanged leader/timer', 'mustLead rejects under-minimum buy', 'pending winner and prize', 'Settle payout', 'pastWinners ordering', 'post-expiry deferred prize', 'Claim prize payout and cleared balance'], liveTransactions: 0 }, null, 2));
} finally {
  fork.kill('SIGTERM');
  if (fork.exitCode === null) await once(fork, 'exit');
}

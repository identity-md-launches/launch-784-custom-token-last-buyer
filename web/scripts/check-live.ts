import assert from 'node:assert/strict';
import { addresses, client, getQuote, hookAbi, readGame, readWinners, verifyDeployment } from '../src/chain';
import { secondsLeft } from '../src/format';

await verifyDeployment();
const snapshot = await readGame();
const { state, block } = snapshot;
const [bank, minimum, left, pending, winners] = await Promise.all([
  client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'bankBalance', blockNumber: block }),
  client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'minimumBuy', blockNumber: block }),
  client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'timeLeft', blockNumber: block }),
  client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'pendingPrize', blockNumber: block }),
  readWinners(),
]);
assert.equal(state.bank, bank); assert.equal(state.minimumBuy, minimum); assert.equal(state.timeLeft, left); assert.equal(state.pendingPrize, pending);
assert.equal(secondsLeft(left, 0, 2000), Math.max(0, Number(left) - 2));
const quote = await getQuote(true, minimum * 2n, addresses.win, true);
assert.ok(quote > 0n);
console.log(JSON.stringify({ result: 'PASS', block, timestamp: snapshot.timestamp, state, pastWinners: winners, quotedBuyInput: minimum * 2n, quotedWinOutput: quote }, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2));

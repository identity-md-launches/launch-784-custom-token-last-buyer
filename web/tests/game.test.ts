import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeAbiParameters, decodeFunctionData, decodeFunctionResult, encodeFunctionResult, parseAbiParameters } from 'viem';
import { addresses, buyerData, gameCall, hookAbi, poolId, poolKey, routerAbi, singleSwapParams, swapCall } from '../src/chain';
import { clockText, estimatedHookFee, minimumText, outputMinimum, parseAmount, secondsLeft } from '../src/format';

test('gameState decodes all 16 fields, including pending-round semantics', () => {
  const expected = { bank: 1000n, nextPrize: 40n, minimumBuy: 85n, leader: '0x0000000000000000000000000000000000000000', timeLeft: 0n, roundNumber: 2n, roundActive: false, deadline: 0n, qualifyingBuysInRound: 0, feePips: 30000n, teamOwed: 30n, winners: 0n, settleable: true, pendingRound: 1n, pendingWinner: addresses.win, pendingPrize: 200n } as const;
  const encoded = encodeFunctionResult({ abi: hookAbi, functionName: 'gameState', result: expected });
  const actual = decodeFunctionResult({ abi: hookAbi, functionName: 'gameState', data: encoded });
  assert.equal(actual.pendingWinner.toLowerCase(), expected.pendingWinner);
  assert.equal(actual.pendingPrize, 200n); assert.equal(actual.nextPrize, 40n);
  assert.equal(actual.pendingRound, 1n); assert.equal(actual.roundNumber, 2n);
  assert.equal(actual.qualifyingBuysInRound, 0); assert.equal(actual.settleable, true);
});
test('pastWinners decodes tuples in round, timestamp, winner, prize order', () => {
  const data = encodeFunctionResult({ abi: hookAbi, functionName: 'pastWinners', result: [{ round: 3n, settledAt: 1700000000n, winner: addresses.win, prize: 250n }] });
  const [winner] = decodeFunctionResult({ abi: hookAbi, functionName: 'pastWinners', data });
  assert.equal(winner.round, 3n); assert.equal(winner.settledAt, 1700000000n); assert.equal(winner.prize, 250n);
});
test('countdown uses elapsed monotonic time, clamps expiry, handles the three-hour first round', () => {
  assert.equal(secondsLeft(600n, 1000, 6500), 595);
  assert.equal(secondsLeft(600n, 1000, 800000), 0);
  assert.equal(secondsLeft(600n, 2000, 1000), 600);
  assert.equal(clockText(10800), '180:00'); assert.equal(clockText(59), '00:59');
});
test('amount validation never silently rounds excess decimals or scientific notation', () => {
  for (const input of ['', '-2', '0', '1e2', '1,000', '0.0000000000000000001', 'NaN']) assert.equal(parseAmount(input), null);
  assert.equal(parseAmount('8.5'), 8500000000000000000n);
  assert.equal(parseAmount('.25'), 250000000000000000n);
});
test('Settle and Claim prize use the correct selectors and connected winner', () => {
  assert.equal(gameCall('settle', addresses.win).to, addresses.hook);
  assert.equal(decodeFunctionData({ abi: hookAbi, data: gameCall('settle', addresses.win).data }).functionName, 'settle');
  const claim = decodeFunctionData({ abi: hookAbi, data: gameCall('claimPrize', addresses.win).data });
  assert.equal(claim.functionName, 'claimPrize');
  assert.equal((claim.args?.[0] as string).toLowerCase(), addresses.win);
});
test('swap uses the pinned single pool, extended router layout, exact limits and explicit buyer', () => {
  assert.equal(poolId, '0x73cede53c18964172f0252bf5b65f7d41c5b55039c753fd69d0abe7373227484');
  const call = swapCall(true, 10n ** 19n, 100n, addresses.win, true, 123456n);
  const decoded = decodeFunctionData({ abi: routerAbi, data: call.data });
  assert.equal(decoded.args[0], '0x10'); assert.equal(decoded.args[2], 123456n);
  const [actions, params] = decodeAbiParameters(parseAbiParameters('bytes,bytes[]'), decoded.args[1][0]);
  assert.equal(actions, '0x060c0f');
  const [swap] = decodeAbiParameters(singleSwapParams, params[0]);
  assert.equal(swap.poolKey.hooks.toLowerCase(), poolKey.hooks);
  assert.equal(swap.zeroForOne, true); assert.equal(swap.minHopPriceX36, 0n);
  assert.equal(swap.amountOutMinimum, 100n); assert.equal(swap.hookData, buyerData(addresses.win, true));
  assert.equal(decodeAbiParameters(parseAbiParameters('address,uint256'), params[1])[1], 10n ** 19n);
  const sell = decodeFunctionData({ abi: routerAbi, data: swapCall(false, 100n, 1n, addresses.win, true, 1n).data });
  const [, sellParams] = decodeAbiParameters(parseAbiParameters('bytes,bytes[]'), sell.args[1][0]);
  const [sellSwap] = decodeAbiParameters(singleSwapParams, sellParams[0]);
  assert.equal(sellSwap.zeroForOne, false); assert.equal(sellSwap.hookData, buyerData(addresses.win, false));
});
test('minimum output and fee calculations use integer arithmetic', () => {
  assert.equal(outputMinimum(100000n, 50), 99500n);
  assert.equal(estimatedHookFee(true, 10000n, 0n, 30000n), 300n);
  assert.equal(estimatedHookFee(false, 0n, 9700n, 30000n), 300n);
  assert.equal(minimumText(8500000000000000001n), '8.5001');
});

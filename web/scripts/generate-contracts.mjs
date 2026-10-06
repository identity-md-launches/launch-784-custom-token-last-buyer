import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import { keccak256, toHex, createPublicClient, http } from 'viem';

// Run from web/. All inputs are retained in this repository; no parent-job files required.
const root = process.env.WIN_SOURCE_ROOT || path.resolve('..');
const deployment = JSON.parse(fs.readFileSync('src/generated/deployment.json', 'utf8'));
const { network } = JSON.parse(fs.readFileSync('src/generated/network.json', 'utf8'));
const sources = Object.fromEntries(['WinToken', 'WinGameHook'].map(name => [
  `src/${name}.sol`, { content: fs.readFileSync(`${root}/src/${name}.sol`, 'utf8') },
]));
const result = JSON.parse(solc.compile(JSON.stringify({ language: 'Solidity', sources, settings: {
  optimizer: { enabled: true, runs: 1000 }, evmVersion: 'cancun',
  metadata: { bytecodeHash: 'none', appendCBOR: false },
  outputSelection: { '*': { '*': ['abi', 'evm.deployedBytecode'] } },
} }), { import: name => {
  const file = path.join(root, name.replace(/^v4-core\//, 'lib/v4-core/'));
  return { contents: fs.readFileSync(file, 'utf8') };
} }));
const errors = result.errors?.filter(e => e.severity === 'error');
if (errors?.length) throw Error(JSON.stringify(errors));
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])])) : value;
const client = createPublicClient({ transport: http(network.rpcUrls[0]) });
if (await client.getChainId() !== deployment.chainId) throw Error('Wrong chain');
const proof = { chainId: deployment.chainId, sourceCommit: deployment.sourceCommit, blockNumber: String(await client.getBlockNumber()), contracts: [] };
let generated = '// Generated from pinned Solidity by scripts/generate-contracts.mjs. Do not edit.\n';
for (const item of deployment.contracts) {
  const artifact = result.contracts[`src/${item.name}.sol`][item.name];
  // Foundry groups ABI entries before hashing; retain Solidity's order within each group.
  const kinds = ['constructor', 'fallback', 'receive', 'function', 'event', 'error'];
  artifact.abi.sort((a, b) => kinds.indexOf(a.type) - kinds.indexOf(b.type));
  const hash = keccak256(toHex(JSON.stringify(canonical(artifact.abi)))).slice(2);
  if (hash !== item.abiHash) throw Error(`${item.name} ABI mismatch: ${hash}`);
  const code = await client.getCode({ address: item.address });
  if (!code || code === '0x') throw Error(`No deployed code: ${item.name}`);
  const mask = hex => {
    const bytes = Buffer.from(hex.replace(/^0x/, ''), 'hex');
    for (const ranges of Object.values(artifact.evm.deployedBytecode.immutableReferences))
      for (const range of ranges) bytes.fill(0, range.start, range.start + range.length);
    return bytes.toString('hex');
  };
  if (mask(code) !== mask(artifact.evm.deployedBytecode.object)) throw Error(`${item.name} runtime mismatch`);
  proof.contracts.push({ name: item.name, address: item.address, abiHash: hash, runtimeHash: keccak256(code), sourceRuntimeMatched: true });
  const name = item.name === 'WinGameHook' ? 'hookAbi' : 'tokenAbi';
  generated += `export const ${name} = ${JSON.stringify(artifact.abi, null, 2)} as const;\n`;
}
for (const [name, address] of Object.entries(network.uniswapV4)) {
  if (typeof address !== 'string' || !address.startsWith('0x')) continue;
  const code = await client.getCode({ address });
  if (!code || code === '0x') throw Error(`No code: ${name}`);
  proof.contracts.push({ name, address, runtimeHash: keccak256(code) });
}
fs.writeFileSync('src/generated/contracts.ts', generated);
fs.writeFileSync('src/generated/verification.json', JSON.stringify(proof, null, 2) + '\n');
console.log(JSON.stringify(proof, null, 2));

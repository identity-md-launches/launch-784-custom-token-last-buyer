import { formatUnits, parseUnits, type Address } from 'viem';

export const shortAddress = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
export function amountText(value: bigint, digits = 4) {
  const [whole, fraction = ''] = formatUnits(value, 18).split('.');
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const decimal = fraction.slice(0, digits).replace(/0+$/, '');
  if (value > 0n && whole === '0' && !decimal) return `< ${'0.' + '0'.repeat(digits - 1) + '1'}`;
  return grouped + (decimal ? `.${decimal}` : '');
}
export function parseAmount(text: string) {
  if (!/^(\d+\.?\d*|\.\d+)$/.test(text) || (text.split('.')[1]?.length ?? 0) > 18) return null;
  const value = parseUnits(text, 18);
  return value > 0n && value < 2n ** 128n ? value : null;
}
// A displayed qualifying threshold must never round down below the contract's value.
export function minimumText(value: bigint) {
  const step = 10n ** 14n;
  return amountText((value + step - 1n) / step * step, 4);
}
export function secondsLeft(timeLeft: bigint, receivedAt: number, now: number) {
  return Math.max(0, Number(timeLeft) - Math.floor(Math.max(0, now - receivedAt) / 1000));
}
export function clockText(seconds: number) {
  const s = Math.max(0, Math.floor(seconds));
  const m = Math.floor(s / 60);
  return `${String(m).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}
export function outputMinimum(output: bigint, slippageBps: number) { return output * BigInt(10_000 - slippageBps) / 10_000n; }
export function estimatedHookFee(buy: boolean, input: bigint, output: bigint, feePips: bigint) {
  return buy ? input * feePips / 1_000_000n : output * feePips / (1_000_000n - feePips);
}
export function errorText(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  if (/reject|denied/i.test(message)) return 'Request declined in your wallet. You can try again when ready.';
  if (/NotQualifying|must lead/i.test(message)) return 'The minimum buy changed. Increase the amount or turn off “Require taking the lead”, then refresh the quote.';
  if (/insufficient/i.test(message)) return 'Check your token balance and ETH for network gas, then try again.';
  return message.split('\n')[0].slice(0, 240);
}
export function isSameAccount(a: Address | undefined, b: Address | undefined) { return a?.toLowerCase() === b?.toLowerCase(); }

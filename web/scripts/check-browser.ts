import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { chromium, type Page } from 'playwright';
import AxeBuilder from '@axe-core/playwright';
import { decodeFunctionData } from 'viem';
import { hookAbi } from '../src/chain';

export async function checkBrowser(forkUrl: string, buyer: string) {
  const artifactDir = resolve('../artifacts');
  await mkdir(artifactDir, { recursive: true });
  const server = createServer(async (req, res) => {
    try {
      if (req.url === '/rpc') {
        const chunks: Buffer[] = []; for await (const chunk of req) chunks.push(chunk);
        const response = await fetch(forkUrl, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: Buffer.concat(chunks).toString() });
        res.setHeader('Content-Type', 'application/json'); res.end(await response.text()); return;
      }
      const file = resolve('../dist', decodeURIComponent((req.url ?? '').replace(/^\/preview\/?/, '').split('?')[0]) || 'index.html');
      if (!file.startsWith(resolve('../dist') + '/')) { res.writeHead(404); res.end(); return; }
      const mime: Record<string, string> = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
      res.setHeader('Content-Type', mime[extname(file)] ?? 'application/octet-stream'); res.end(await readFile(file));
    } catch { res.writeHead(404); res.end(); }
  });
  server.listen(0, '127.0.0.1');
  await new Promise<void>(r => server.once('listening', r));
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}/preview/`;
  const browser = await chromium.launch({ executablePath: process.env.WIN_CHROME || '/opt/google/chrome/chrome', args: ['--no-sandbox'] });
  let activePage: Page | undefined;
  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await context.newPage();
    activePage = page;
    const errors: string[] = []; page.on('pageerror', error => errors.push(error.message));
    const failures: string[] = []; page.on('response', response => { if (response.status() >= 400) failures.push(`${response.status()} ${response.url()}`); });
    let failRpc = false;
    await page.route(/https:\/\/(robinhood-rpc.publicnode.com|rpc.mainnet.chain.robinhood.com)/, async route => {
      if (failRpc) { await route.abort(); return; }
      const response = await fetch(forkUrl, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: route.request().postData() });
      await route.fulfill({ status: 200, contentType: 'application/json', body: await response.text() });
    });
    await page.addInitScript(({ buyer }) => {
      // tsx preserves inferred function names; serialized Playwright callbacks need this helper.
      Object.defineProperty(window, '__name', { value: new Function('fn', 'return fn'), configurable: true });
      const testWindow = window as any;
      const listeners: Record<string, Function[]> = {};
      let selectedChain = '0x1'; let added = false;
      testWindow.walletRequests = []; testWindow.rejectNext = false;
      testWindow.ethereum = {
        on: (name: string, callback: Function) => { (listeners[name] ??= []).push(callback); },
        removeListener: (name: string, callback: Function) => { listeners[name] = (listeners[name] ?? []).filter(x => x !== callback); },
        request: async ({ method, params }: { method: string; params?: unknown[] }) => {
          testWindow.walletRequests.push({ method, params });
          if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [buyer];
          if (method === 'eth_chainId') return selectedChain;
          if (method === 'wallet_switchEthereumChain') {
            if (!added) throw { code: 4902, message: 'Unknown chain' };
            selectedChain = '0x1237'; for (const fn of listeners.chainChanged ?? []) fn(selectedChain); return null;
          }
          if (method === 'wallet_addEthereumChain') { added = true; return null; }
          if (method === 'eth_sendTransaction' && testWindow.rejectNext) { testWindow.rejectNext = false; throw { code: 4001, message: 'User rejected the request.' }; }
          const response = await fetch('/rpc', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params: params ?? [] }) });
          const data = await response.json(); if (data.error) throw data.error; return data.result;
        },
      };
    }, { buyer });
    await page.goto(url);
    await page.getByRole('button', { name: 'Settle round' }).waitFor();
    await page.getByRole('button', { name: 'Connect wallet', exact: true }).click();
    try { await page.getByRole('button', { name: 'Claim prize', exact: true }).waitFor(); }
    catch (e) { console.log(await page.locator('body').innerText()); console.log(await page.evaluate(() => (window as any).walletRequests)); throw e; }
    await page.waitForFunction(() => !(document.querySelector('.prize-card button') as HTMLButtonElement)?.disabled);
    await page.getByRole('button', { name: 'Settle round', exact: true }).click();
    await page.getByText('Confirmed on Robinhood Chain.', { exact: false }).waitFor();
    await page.getByRole('button', { name: 'Claim prize', exact: true }).click();
    await page.getByRole('button', { name: 'Claim prize', exact: true }).waitFor({ state: 'detached' });
    const requestMethods = await page.evaluate(() => (window as any).walletRequests.map((r: any) => r.method));
    assert.ok(requestMethods.includes('wallet_addEthereumChain'));
    assert.ok(requestMethods.includes('wallet_switchEthereumChain'));
    let requests = await page.evaluate(() => (window as any).walletRequests);
    const gameWrites = requests.filter((r: any) => r.method === 'eth_sendTransaction').map((r: any) => decodeFunctionData({ abi: hookAbi, data: r.params[0].data }).functionName);
    assert.deepEqual(gameWrites, ['settle', 'claimPrize']);
    await page.locator('nav').getByRole('link', { name: 'Buy & sell' }).click();
    await page.getByRole('button', { name: 'Review buy WIN' }).click();
    await page.getByText('Enter an amount greater than zero', { exact: false }).waitFor();
    assert.equal(await page.locator('#amount').evaluate(el => el === document.activeElement), true);
    await page.getByRole('textbox', { name: 'You pay' }).fill('0.1');
    await page.getByText('Below the current minimum', { exact: false }).waitFor();
    await page.getByRole('button', { name: 'Use current minimum', exact: false }).click();
    await page.getByText('Quote valid for 30 seconds', { exact: true }).waitFor();
    await page.evaluate(() => { (window as any).rejectNext = true; });
    await page.getByRole('button', { name: 'Review buy WIN' }).click();
    await page.getByText('Request declined in your wallet.', { exact: false }).waitFor();
    await page.getByRole('button', { name: 'Refresh quote', exact: false }).click();
    await page.getByText('Quoting…', { exact: true }).waitFor();
    await page.getByText('Quote valid for 30 seconds', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Review buy WIN' }).click();
    await page.waitForFunction(() => document.querySelector('.transaction-status')?.textContent?.startsWith('Confirmed'));
    await page.waitForFunction(() => (document.querySelector('#amount') as HTMLInputElement)?.value === '');
    await page.getByRole('button', { name: 'Sell WIN', exact: true }).click();
    await page.getByRole('textbox', { name: 'You pay' }).fill('1000');
    await page.getByText('Quote valid for 30 seconds', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Review sell WIN' }).click();
    await page.waitForFunction(() => (document.querySelector('#amount') as HTMLInputElement)?.value === '');
    const axes: { page: string; violations: string[] }[] = [];
    const layout: { page: string; width: number; scrollWidth: number }[] = [];
    for (const route of ['game', 'trade', 'rules']) {
      await page.goto(`${url}#${route}`); await page.waitForTimeout(1000);
      if (route === 'trade') { await page.getByRole('button', { name: 'Use current minimum', exact: false }).click(); await page.getByText('Quote valid for 30 seconds', { exact: true }).waitFor(); }
      for (const width of [1440, 768, 390, 320]) {
        await page.setViewportSize({ width, height: 1000 });
        const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
        assert.ok(scrollWidth <= width, `${route}: overflow at ${width}`); layout.push({ page: route, width, scrollWidth });
      }
      const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze();
      axes.push({ page: route, violations: axe.violations.map(v => `${v.id}: ${v.nodes.map(n => n.target).join(', ')}`) });
      assert.equal(axe.violations.length, 0, JSON.stringify(axes.at(-1)));
    }
    await page.getByRole('button', { name: 'Copy WIN token address', exact: true }).click();
    await page.getByText('Copied', { exact: true }).waitFor();
    await page.getByText('Pool ID and network details', { exact: true }).click();
    assert.equal(await page.locator('details').getAttribute('open'), '');
    // Keyboard route, native reflow and reduced-motion state.
    await page.goto(`${url}?keyboard=1#trade`); await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Skip to content');
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => document.activeElement?.id), 'main');
    assert.equal(new URL(page.url()).hash, '#trade', 'Skip link changed the route');
    await page.emulateMedia({ reducedMotion: 'reduce' });
    assert.equal(await page.locator('.connect').evaluate(el => getComputedStyle(el).transitionDuration), '0s');
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 1440, 'Text enlargement caused page overflow');
    await page.evaluate(() => { document.documentElement.style.fontSize = ''; });
    await page.locator('nav').getByRole('link', { name: 'The game', exact: true }).click();
    failRpc = true;
    await page.getByRole('button', { name: 'Refresh game state' }).click();
    await page.getByRole('button', { name: 'Retry live data' }).waitFor({ timeout: 30000 });
    failRpc = false;
    await page.getByRole('button', { name: 'Retry live data' }).click();
    await page.getByRole('button', { name: 'Retry live data' }).waitFor({ state: 'detached' });
    assert.deepEqual(errors, []); assert.deepEqual(failures, []);
    requests = await page.evaluate(() => (window as any).walletRequests);
    const report = { result: 'PASS', source: 'production dist under /preview/, reads and writes redirected to local Anvil fork', browser: await browser.version(), tests: ['network add/switch', 'Settle button transaction and winner payment', 'Claim prize button transaction', 'form error and focus', 'qualifying minimum', 'wallet rejection and retry', 'buy with approvals', 'sell with approvals', 'hash navigation', 'address copy', 'pool disclosure', 'skip-link keyboard focus', 'reduced motion', '200% text enlargement', 'RPC outage and retry'], layout, axes, consoleErrors: errors, httpFailures: failures, liveTransactions: 0 };
    await writeFile(resolve(artifactDir, 'browser-validation.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
    await context.close();
  } catch (error) {
    if (activePage) console.log('Browser failure state:', await activePage.locator('body').innerText());
    throw error;
  } finally { await browser.close(); server.close(); }
}

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { encodeFunctionData, formatUnits, type Address, type EIP1193Provider, type Hex } from 'viem';
import {
  addresses, assertAccount, chain, client, deployment, gameCall, getQuote, hookAbi, network,
  permitAbi, poolId, sendCall, swapCall, switchNetwork, tokenAbi, type Winner,
} from './chain';
import { amountText, clockText, errorText, estimatedHookFee, minimumText, outputMinimum, parseAmount, secondsLeft, shortAddress } from './format';
import { useGame } from './useGame';

type Provider = EIP1193Provider & { on?: (event: string, callback: (...args: any[]) => void) => void; removeListener?: (event: string, callback: (...args: any[]) => void) => void };
declare global { interface Window { ethereum?: Provider } }
type Page = 'game' | 'trade' | 'rules';
type Game = ReturnType<typeof useGame>;
const readPage = (): Page => location.hash === '#trade' ? 'trade' : location.hash === '#rules' ? 'rules' : 'game';
const explorer = (address: string) => `${network.explorer}/address/${address}`;

function Mark({ small = false }: { small?: boolean }) {
  return <svg className={small ? 'mark small' : 'mark'} viewBox="0 0 64 64" aria-hidden="true"><path d="m10 18 8 29 14-20 14 20 8-29" fill="none" stroke="currentColor" strokeWidth="7" strokeLinejoin="round" /></svg>;
}
function Arrow() { return <span aria-hidden="true">↗</span>; }
function AddressLink({ value, full = false }: { value: Address; full?: boolean }) {
  return <a className={full ? 'address full-address' : 'address'} href={explorer(value)} target="_blank" rel="noreferrer" aria-label={`${value} on the explorer`} title={value}>{full ? value : shortAddress(value)} <Arrow /></a>;
}
function Tag({ children, warning = false }: { children: ReactNode; warning?: boolean }) {
  return <span className={`tag ${warning ? 'warning' : ''}`}><span className="dot" />{children}</span>;
}
function CopyButton({ value, label }: { value: string; label: string }) {
  const [message, setMessage] = useState('');
  return <div className="copy-control"><button className="button small-button" type="button" aria-label={`Copy ${label} address`} onClick={async () => {
    try { await navigator.clipboard.writeText(value); setMessage('Copied'); }
    catch { setMessage('Select and copy the address'); }
  }}>Copy</button><span className="copy-status" role="status">{message}</span></div>;
}
function Stat({ title, children, note }: { title: string; children: ReactNode; note: string }) {
  return <div className="stat"><dt>{title}</dt><dd>{children}<p>{note}</p></dd></div>;
}

export default function App() {
  const [page, setPage] = useState<Page>(readPage);
  const [account, setAccount] = useState<Address>();
  const [walletChain, setWalletChain] = useState<number>();
  const [walletError, setWalletError] = useState('');
  const [connecting, setConnecting] = useState(false);
  const [busy, setBusy] = useState(false);
  const [txStatus, setTxStatus] = useState('');
  const [txError, setTxError] = useState('');
  const [txHash, setTxHash] = useState<Hex>();
  const game = useGame(account);
  const main = useRef<HTMLElement>(null);
  const wrongNetwork = !!account && walletChain !== chain.id;
  useEffect(() => {
    const route = () => { setPage(readPage()); requestAnimationFrame(() => main.current?.focus()); window.scrollTo(0, 0); };
    window.addEventListener('hashchange', route);
    return () => window.removeEventListener('hashchange', route);
  }, []);
  useEffect(() => { document.title = `${page === 'game' ? 'Last buyer wins' : page === 'trade' ? 'Trade WIN / IMD' : 'How it works'} — WIN`; }, [page]);
  const trackWallet = useCallback(async () => {
    const provider = window.ethereum;
    if (!provider) return;
    try {
      const list = await provider.request({ method: 'eth_accounts' });
      const id = await provider.request({ method: 'eth_chainId' });
      setAccount(list[0]); setWalletChain(Number(id));
    } catch { setAccount(undefined); }
  }, []);
  useEffect(() => {
    const provider = window.ethereum;
    const changed = () => { void trackWallet(); };
    const disconnected = () => { setAccount(undefined); setWalletChain(undefined); };
    provider?.on?.('accountsChanged', changed); provider?.on?.('chainChanged', changed); provider?.on?.('disconnect', disconnected);
    return () => { provider?.removeListener?.('accountsChanged', changed); provider?.removeListener?.('chainChanged', changed); provider?.removeListener?.('disconnect', disconnected); };
  }, [trackWallet]);
  const connect = async () => {
    setWalletError(''); setConnecting(true);
    try {
      if (!window.ethereum) throw Error('Open this site in a wallet browser or enable an Ethereum wallet extension, then connect again. Reading the game needs no wallet.');
      await window.ethereum.request({ method: 'eth_requestAccounts' });
      await trackWallet();
      await switchNetwork(window.ethereum); await trackWallet();
    } catch (e) { setWalletError(errorText(e)); }
    finally { setConnecting(false); }
  };
  const onHash = (hash: Hex) => { setTxHash(hash); setTxStatus('Transaction sent. Waiting for confirmation…'); };
  const transact = async (fn: () => Promise<void>) => {
    if (busy) return;
    setBusy(true); setTxError(''); setTxHash(undefined); setTxStatus('Review the request in your wallet.');
    try { await fn(); setTxStatus('Confirmed on Robinhood Chain.'); await game.refresh(); await game.refreshHistory(); }
    catch (e) { setTxStatus(''); setTxError(errorText(e)); }
    finally { setBusy(false); }
  };
  const action = async (name: 'settle' | 'claimPrize') => {
    if (!account || !window.ethereum) { await connect(); return; }
    const provider = window.ethereum;
    await transact(async () => {
      if (!game.verified || game.stale) throw Error('Refresh live data and wait for contract verification before continuing.');
      await sendCall(provider, account, gameCall(name, account), onHash);
    });
  };
  const canAct = game.verified && !game.stale && !wrongNetwork && !busy;
  const nav: [Page, string][] = [['game', 'The game'], ['trade', 'Buy & sell'], ['rules', 'How it works']];
  return <>
    <a className="skip-link" href="#main" onClick={event => { event.preventDefault(); main.current?.focus(); main.current?.scrollIntoView(); }}>Skip to content</a>
    <header className="site-header shell">
      <a className="brand" href="#game" aria-label="WIN home"><Mark /><span>WIN<span className="brand-period">.</span></span></a>
      <nav aria-label="Main navigation">{nav.map(([key, label]) => <a key={key} href={`#${key}`} aria-current={page === key ? 'page' : undefined}>{label}</a>)}</nav>
      <button type="button" className="button connect" disabled={connecting || busy} onClick={() => void connect()}>{connecting ? 'Connecting…' : account ? shortAddress(account) : 'Connect wallet'}<span className="wallet-icon" aria-hidden="true">◧</span></button>
    </header>
    <div className="network-line shell"><span className="network-label"><span className="dot" /> Robinhood Chain <span className="muted">/ Mainnet</span></span><span className="network-aside">Onchain. Open to everyone.</span></div>
    <div className="shell notices">
      {walletError && <p className="notice error" role="alert">{walletError}</p>}
      {wrongNetwork && <div className="notice"><span>Your wallet is on a different network. Switch to Robinhood Chain (4663) to continue.</span><button className="button" disabled={busy} onClick={() => void connect()}>Switch network</button></div>}
      {(game.error || game.stale) && <div className="notice warning-notice"><span>{game.error || 'The latest block is delayed. Values below may be stale; transactions are paused.'}</span><button className="button" onClick={() => void game.refresh()}>Retry live data</button></div>}
      {game.verifyError && <div className="notice error"><span>{game.verifyError}</span><button className="button" onClick={() => void game.verify()}>Retry verification</button></div>}
      <div className="transaction-status" role="status">{txStatus}{txHash && <> <a href={`${network.explorer}/tx/${txHash}`} target="_blank" rel="noreferrer">View transaction <Arrow /></a></>}</div>
      {txError && <p className="notice error" role="alert">{txError} {txHash && <a href={`${network.explorer}/tx/${txHash}`} target="_blank" rel="noreferrer">Check transaction status</a>}</p>}
      {game.claimError && <p className="notice">{game.claimError}</p>}
      {game.unclaimed > 0n && <div className="notice claim-notice"><span><strong>{amountText(game.unclaimed)} IMD is ready to claim.</strong> This prize belongs to your connected wallet.</span><button className="button" disabled={!canAct} onClick={() => void action('claimPrize')}>Claim prize</button></div>}
    </div>
    <main id="main" className="shell" ref={main} tabIndex={-1}>
      {page === 'game' ? <GamePage game={game} canAct={canAct} busy={busy} settle={() => void action('settle')} /> :
        page === 'trade' ? <TradePage game={game} account={account} canAct={canAct} busy={busy} wrongNetwork={wrongNetwork} connect={connect} transact={transact} onHash={onHash} setTxStatus={setTxStatus} /> : <RulesPage />}
    </main>
    <footer className="shell site-footer">
      <div className="footer-top"><a className="brand footer-brand" href="#game"><Mark small /><span>WIN.</span></a><p>The clock is onchain.<br /> The last qualifying buyer wins.</p><a href={deployment.repoUrl} target="_blank" rel="noreferrer">View GitHub source <Arrow /></a></div>
      <div className="risk-notice">Made by agents. Not audited by humans. Trade at your own risk.</div>
      <div className="footer-bottom"><span>WIN / IMD · Uniswap v4</span><span>Chain 4663 · Read without a wallet</span></div>
    </footer>
  </>;
}

function GamePage({ game, canAct, busy, settle }: { game: Game; canAct: boolean; busy: boolean; settle: () => void }) {
  const s = game.snapshot?.state;
  const pending = s?.settleable;
  const seconds = game.snapshot ? secondsLeft(s!.timeLeft, game.snapshot.receivedAt, game.now) : 0;
  const awaitingBlock = !!s?.roundActive && seconds === 0;
  const leader = pending ? s.pendingWinner : s?.leader;
  return <>
    <section className="page-intro"><div><p className="eyebrow">A game of timing</p><h1>Be the last.<br /> <span className="heading-muted">Take the prize.</span></h1></div><p className="intro-copy">Every qualifying buy resets the clock.<br /> Stay in the lead until it runs out.</p></section>
    <section className="game-grid" aria-label="Current round">
      <div className="countdown-card">
        <div className="card-top"><span className="eyebrow">Round {s ? String(pending ? s.pendingRound : s.roundNumber).padStart(2, '0') : '—'}</span><Tag warning={game.stale || !!pending}>{game.stale ? 'Data delayed' : !s ? 'Connecting to chain' : pending ? 'Ready to settle' : s.roundActive ? 'Round in progress' : 'Waiting for a buyer'}</Tag></div>
        <div className="clock-area"><p className="clock-caption">{pending ? 'The round has ended' : s?.roundActive ? 'Time until the round ends' : s ? 'The next round starts with a qualifying buy' : 'Reading the live game'}</p><div className={`countdown ${pending ? 'finished' : ''}`} role="timer" aria-label={s ? `${seconds} seconds remaining` : 'Loading countdown'}>{s ? clockText(seconds) : '—:—'}</div><p className="clock-note">{game.stale ? 'Countdown is an estimate until live data resumes.' : pending ? 'The prize is waiting. Anyone can settle this round.' : awaitingBlock ? 'Checking the next block for settlement…' : s?.roundActive ? s.roundNumber === 1n ? 'First round: at least three hours after launch.' : 'A qualifying buy resets the clock to ten minutes.' : 'No active timer yet.'}</p></div>
        <div className="leader-row"><span className="leader-symbol" aria-hidden="true">♜</span><div><span className="caption">{pending ? 'Pending winner' : 'Current leader'}</span><div>{leader && leader !== '0x0000000000000000000000000000000000000000' ? <AddressLink value={leader} /> : <span className="leader-empty">{s ? 'The lead is open' : 'Reading leader…'}</span>}</div></div><span className="leader-trail" aria-hidden="true">↗</span></div>
      </div>
      <div className="prize-card"><div className="card-top"><span className="eyebrow">{pending ? 'Pending prize' : 'Current prize'}</span><span className="coin-badge">IMD</span></div><div className="prize-amount">{s ? amountText(pending ? s.pendingPrize : s.nextPrize, 2) : '—'}<span>IMD</span></div><p>{pending ? 'Reserved for the winner above.' : 'One leader. The whole round prize.'}</p><div className="prize-rule"><span>{s ? (pending ? s.pendingRound : s.roundNumber) === 1n ? '20%' : '5%' : '—'}</span> of the bank for this round</div>{pending ? <button className="button primary" disabled={!canAct} onClick={settle}>{busy ? 'Settling…' : 'Settle round'} <Arrow /></button> : <a className="button primary" href="#trade">Buy WIN <Arrow /></a>}<span className="prize-footnote">{pending ? 'Settlement pays the winner, whoever calls it.' : 'Trading involves risk. Winning is not guaranteed.'}</span></div>
    </section>
    <dl className="stats-grid"><Stat title="Prize bank" note="IMD reserved for future prizes">{s ? amountText(s.bank, 2) : '—'} <small>IMD</small></Stat><Stat title="Minimum buy to lead" note={pending ? 'Minimum for the next round' : 'Gross IMD · display rounded up'}>{s ? minimumText(s.minimumBuy) : '—'} <small>IMD</small></Stat><Stat title="Qualifying buys" note={pending ? `Next round · ${s.roundNumber}` : 'In the current round'}>{s ? s.qualifyingBuysInRound : '—'} <small>{s?.qualifyingBuysInRound === 1 ? 'buy' : 'buys'}</small></Stat></dl>
    <div className="live-source"><span className="dot" /><span>{game.stale ? 'Live feed delayed' : game.snapshot ? `Read from block ${game.snapshot.block.toLocaleString('en-US')}` : 'Loading live contract state…'}</span><span>Refreshes every 5 seconds</span><button type="button" className="text-button" onClick={() => void game.refresh()} aria-label="Refresh game state">Refresh ↻</button></div>
    <section className="winners-section"><div className="section-heading"><div><p className="eyebrow">Written onchain</p><h2>The winners’ circle</h2></div><span className="muted">Every settled round, forever.</span></div>
      {game.historyError ? <div className="empty-state"><p>{game.historyError}</p><button className="button" onClick={() => void game.refreshHistory()}>Retry winner history</button></div> : game.winners === undefined ? <div className="empty-state" aria-busy="true">Reading past winners…</div> : game.winners.length === 0 ? <div className="empty-state"><span className="empty-icon" aria-hidden="true">⚑</span><div><h3>The first name is still unwritten.</h3><p>Settled rounds will appear here. Follow the clock to see who takes the first prize.</p></div><a href="#rules">Read the rules <Arrow /></a></div> : <WinnersTable winners={game.winners} />}
    </section>
    <section className="rules-teaser"><div><span className="eyebrow">Simple rules. Open code.</span><h2>Buy. Reset. Outlast.</h2><p>A qualifying buy takes the lead. Sells never reset the clock.</p></div><a className="button" href="#rules">See how it works <Arrow /></a></section>
  </>;
}
function WinnersTable({ winners }: { winners: readonly Winner[] }) {
  const [shown, setShown] = useState(10);
  return <><div className="table-scroll" tabIndex={0} role="region" aria-label="Past winners, scroll horizontally if needed"><table><caption className="sr-only">Past winners, latest settled round first. Times are UTC.</caption><thead><tr><th scope="col">Round</th><th scope="col">Winner</th><th scope="col">Prize in IMD</th><th scope="col">Settled at (UTC)</th></tr></thead><tbody>{[...winners].reverse().slice(0, shown).map(w => <tr key={String(w.round)}><td>#{String(w.round)}</td><td><AddressLink value={w.winner} /></td><td>{amountText(w.prize)}</td><td><time dateTime={new Date(Number(w.settledAt) * 1000).toISOString()}>{new Date(Number(w.settledAt) * 1000).toISOString().replace('T', ' ').slice(0, 19)}</time></td></tr>)}</tbody></table></div>{shown < winners.length && <button className="button" onClick={() => setShown(v => v + 10)}>Show more winners</button>}</>;
}

function TradePage({ game, account, canAct, busy, wrongNetwork, connect, transact, onHash, setTxStatus }: {
  game: Game; account?: Address; canAct: boolean; busy: boolean; wrongNetwork: boolean;
  connect: () => Promise<void>; transact: (fn: () => Promise<void>) => Promise<void>;
  onHash: (hash: Hex) => void; setTxStatus: (text: string) => void;
}) {
  const [buy, setBuy] = useState(true);
  const [text, setText] = useState('');
  const [mustLead, setMustLead] = useState(true);
  const [slippage, setSlippage] = useState(50);
  const [quote, setQuote] = useState<{ output: bigint; key: string; at: number }>();
  const [quoteError, setQuoteError] = useState('');
  const [quoting, setQuoting] = useState(false);
  const [revision, setRevision] = useState(0);
  const [inputError, setInputError] = useState('');
  const [balance, setBalance] = useState<bigint>();
  const input = useRef<HTMLInputElement>(null);
  const amount = parseAmount(text);
  const s = game.snapshot?.state;
  const inputSymbol = buy ? 'IMD' : 'WIN';
  const outputSymbol = buy ? 'WIN' : 'IMD';
  const quoteKey = `${buy}:${text}:${account}:${mustLead}:${slippage}:${revision}`;
  const freshQuote = quote?.key === quoteKey && game.now - quote.at < 30_000 ? quote : undefined;
  const qualifies = buy && !!amount && !!s && amount >= s.minimumBuy;
  useEffect(() => {
    let active = true; setBalance(undefined);
    if (account) client.readContract({ address: buy ? addresses.imd : addresses.win, abi: tokenAbi, functionName: 'balanceOf', args: [account] })
      .then(value => { if (active) setBalance(value); }).catch(() => {});
    return () => { active = false; };
  }, [account, buy, game.snapshot?.block]);
  useEffect(() => {
    let active = true;
    setQuote(undefined); setQuoteError(''); setQuoting(false);
    if (!amount || !s || game.stale || (buy && mustLead && amount < s.minimumBuy)) return;
    setQuoting(true);
    const timer = setTimeout(() => {
      getQuote(buy, amount, account ?? addresses.win, mustLead)
        .then(output => { if (active) { if (output <= 0n) throw Error('No output is available for this amount.'); setQuote({ output, key: quoteKey, at: performance.now() }); } })
        .catch(e => { if (active) setQuoteError(`Could not quote this trade. Check the amount and available liquidity, then refresh. ${errorText(e)}`); })
        .finally(() => { if (active) setQuoting(false); });
    }, 450);
    return () => { active = false; clearTimeout(timer); };
    // Quote is stable for review, expires after 30 seconds, and is simulated again before sending.
  }, [quoteKey, revision, !!s, game.stale]);
  const submit = async (event: React.FormEvent) => {
    event.preventDefault(); setInputError('');
    if (!amount) { setInputError('Enter an amount greater than zero, with at most 18 decimal places.'); input.current?.focus(); return; }
    if (!account || !window.ethereum || wrongNetwork) { await connect(); return; }
    if (!freshQuote) { setInputError('Get a fresh quote before continuing.'); setRevision(v => v + 1); return; }
    if (!canAct) { setInputError('Wait for live data and contract verification, then try again.'); return; }
    if (balance !== undefined && amount > balance) { setInputError(`You need more ${inputSymbol} for this trade.`); input.current?.focus(); return; }
    const provider = window.ethereum;
    const owner = account;
    const quoted = freshQuote;
    const minimum = outputMinimum(quoted.output, slippage);
    await transact(async () => {
      await assertAccount(provider, owner);
      const token = buy ? addresses.imd : addresses.win;
      const approval = await client.readContract({ address: token, abi: tokenAbi, functionName: 'allowance', args: [owner, addresses.permit2] });
      if (approval < amount) {
        // Zero first for tokens that disallow changing a nonzero allowance directly.
        if (approval > 0n) {
          setTxStatus('Reset the existing token allowance in your wallet.');
          await sendCall(provider, owner, { to: token, data: encodeFunctionData({ abi: tokenAbi, functionName: 'approve', args: [addresses.permit2, 0n] }) }, onHash);
        }
        setTxStatus(`Approve exactly ${formatUnits(amount, 18)} ${inputSymbol} for Permit2 in your wallet.`);
        await sendCall(provider, owner, { to: token, data: encodeFunctionData({ abi: tokenAbi, functionName: 'approve', args: [addresses.permit2, amount] }) }, onHash);
      }
      const block = await client.getBlock();
      const [allowance, expiration] = await client.readContract({ address: addresses.permit2, abi: permitAbi, functionName: 'allowance', args: [owner, token, addresses.router] });
      if (allowance < amount || BigInt(expiration) <= block.timestamp + 300n) {
        setTxStatus('Authorize the router for this amount. This Permit2 allowance expires in 20 minutes.');
        await sendCall(provider, owner, { to: addresses.permit2, data: encodeFunctionData({ abi: permitAbi, functionName: 'approve', args: [token, addresses.router, amount, Number(block.timestamp + 1200n)] }) }, onHash);
      }
      if (performance.now() - quoted.at > 30_000) throw Error('Approvals are complete. Refresh the quote and review the output before swapping.');
      const latest = await client.getBlock();
      setTxStatus(`Review the ${buy ? 'buy' : 'sell'} in your wallet. Minimum received: ${formatUnits(minimum, 18)} ${outputSymbol}.`);
      await sendCall(provider, owner, swapCall(buy, amount, minimum, owner, mustLead, latest.timestamp + 300n), onHash);
      setText(''); setQuote(undefined);
    });
  };
  return <>
    <section className="page-intro"><div><p className="eyebrow">WIN / IMD · Uniswap v4</p><h1>Your next move.</h1></div><p className="intro-copy">Trade through the game’s pool.<br /> A qualifying buy puts you in the lead.</p></section>
    <div className="trade-layout">
    <form className="swap-card" onSubmit={event => void submit(event)} noValidate>
      <div className="swap-tabs" role="group" aria-label="Trade direction"><button type="button" aria-pressed={buy} disabled={busy} onClick={() => { setBuy(true); setText(''); }}>Buy WIN</button><button type="button" aria-pressed={!buy} disabled={busy} onClick={() => { setBuy(false); setText(''); }}>Sell WIN</button></div>
      <div className="amount-box"><div className="field-top"><label htmlFor="amount">You pay</label><span>{account ? `Balance: ${balance === undefined ? 'unavailable' : amountText(balance)}` : 'Connect to see balance'}</span></div><div className="amount-row"><input id="amount" ref={input} name="amount" type="text" inputMode="decimal" autoComplete="off" placeholder="0.00" value={text} disabled={busy} aria-invalid={!!inputError} aria-describedby="amount-help amount-error" onChange={e => { setText(e.target.value); setInputError(''); }} /><span className="token"><span className={`token-icon ${buy ? 'imd-icon' : ''}`} aria-hidden="true">{buy ? 'i' : 'w'}</span>{inputSymbol}</span></div>{buy && s && <button className="text-button" type="button" disabled={busy} onClick={() => setText(formatUnits(s.minimumBuy, 18))}>Use current minimum ↗</button>}</div>
      <div className="swap-direction" aria-hidden="true">↓</div>
      <div className="amount-box output-box"><span className="caption">You receive · estimated</span><div className="amount-row"><output className="output-amount" aria-label={`Estimated ${outputSymbol} received`}>{quoting ? 'Quoting…' : freshQuote ? amountText(freshQuote.output) : '—'}</output><span className="token"><span className={`token-icon ${!buy ? 'imd-icon' : ''}`} aria-hidden="true">{buy ? 'w' : 'i'}</span>{outputSymbol}</span></div></div>
      <p id="amount-help" className={`qualification ${qualifies ? 'qualified' : ''}`}>{!buy ? 'Sells do not take the lead or reset the timer.' : !s || game.stale ? 'Waiting for the live minimum.' : !amount ? 'Enter an amount to check whether your buy qualifies.' : qualifies ? '✓ This amount meets the current minimum.' : `Below the current minimum of ${minimumText(s.minimumBuy)} IMD.`}</p>
      {buy && <label className="checkbox-row"><input type="checkbox" checked={mustLead} disabled={busy} onChange={e => setMustLead(e.target.checked)} /><span>Require taking the lead<small>The swap reverts if it does not qualify at execution. Network gas may still be spent.</small></span></label>}
      <dl className="quote-details"><div><dt>Game fee in IMD</dt><dd>{freshQuote && amount && s ? `${buy ? '' : '≈ '}${amountText(estimatedHookFee(buy, amount, freshQuote.output, s.feePips))}` : '—'}</dd></div><div><dt><label htmlFor="slippage">Slippage limit</label></dt><dd><select id="slippage" value={slippage} disabled={busy} onChange={e => setSlippage(Number(e.target.value))}><option value={50}>0.5%</option><option value={100}>1%</option><option value={200}>2%</option></select></dd></div><div><dt>Minimum received</dt><dd>{freshQuote ? `${amountText(outputMinimum(freshQuote.output, slippage))} ${outputSymbol}` : '—'}</dd></div></dl>
      <p id="amount-error" className="field-error" role="alert">{inputError}</p>
      {quoteError && <p className="field-error" role="alert">{quoteError}</p>}
      {buy && amount && s && mustLead && !qualifies && <p className="small-copy">Increase your amount or turn off “Require taking the lead” to quote a smaller buy.</p>}
      <button className="button primary" type="submit" disabled={busy || (!!account && !wrongNetwork && (!game.verified || game.stale))}>{busy ? 'Transaction in progress…' : !account ? 'Connect wallet to trade' : wrongNetwork ? 'Switch to Robinhood Chain' : buy ? 'Review buy WIN' : 'Review sell WIN'} <Arrow /></button>
      <div className="quote-footer"><span>{freshQuote ? 'Quote valid for 30 seconds' : quoting ? 'Reading the pool…' : 'A fresh quote is required'}</span><button type="button" className="text-button" disabled={busy || quoting} onClick={() => setRevision(v => v + 1)}>Refresh quote ↻</button></div>
      <p className="approval-note">Your wallet may request a token approval, a 20-minute Permit2 authorization, then the swap. Approvals are limited to the entered amount. Each transaction costs gas.</p>
      {!game.verified && <p className="small-copy">Waiting for deployed contract verification before enabling transactions.</p>}
    </form><section className="trade-context"><p className="eyebrow">The amount that counts</p><h2>{s ? minimumText(s.minimumBuy) : '—'} <span>IMD</span></h2><p>Minimum gross buy to take the lead right now, rounded up for display. The game fee is included.</p><div className="context-row"><span>Game fee</span><strong>{s ? `${Number(s.feePips) / 10000}%` : 'Reading…'}</strong></div><div className="context-row"><span>Pool liquidity fee</span><strong>{deployment.manifest.pool.fee / 10000}%</strong></div><p className="small-copy">The quote includes both fees. ETH is also needed for network gas.</p><a href="#rules">Understand the game <Arrow /></a><div className="context-note"><span aria-hidden="true">↳</span><p>{s?.settleable ? `Round ${s.pendingRound} has ended. A buy settles it for its winner and joins round ${s.roundNumber}.` : 'The lead can change before your transaction lands. Keep “Require taking the lead” on to protect your qualifying buy.'}</p></div></section></div>
    <section className="interface-section"><p className="eyebrow">Make sure your buy counts</p><h2>The route matters.</h2><div className="interface-grid"><article><span className="rule-number">01</span><h3>This website</h3><p>Uses this exact WIN / IMD pool and passes your connected wallet as the buyer. Qualifying buys credit that wallet, including supported smart wallets.</p></article><article><span className="rule-number">02</span><h3>Other swap interfaces</h3><p>A buy must use this pool and meet the live minimum. Without an explicit buyer, the hook asks the router for its original caller. Check the route and recipient before trading.</p></article><article><span className="rule-number">03</span><h3>What does not count</h3><p>Sells, transfers, airdrop claims, and trades on other pools or exchanges never take the lead. A router without buyer reporting falls back to the transaction signer, which may be a bundler instead of your smart wallet.</p></article></div></section>
  </>;
}

function RulesPage() {
  const contracts: [string, Address][] = [['WIN token', addresses.win], ['Game + prize bank', addresses.hook], ['IMD token', addresses.imd], ['Merkle distributor', addresses.distributor], ['Universal Router', addresses.router], ['Permit2', addresses.permit2]];
  return <>
    <section className="page-intro"><div><p className="eyebrow">The rules are the contract</p><h1>A simple game.<br /> <span className="heading-muted">An open clock.</span></h1></div><p className="intro-copy">No owner. No admin keys.<br /> No changing the rules after launch.</p></section>
    <section className="diagram" aria-label="Game flow"><div><span className="diagram-icon" aria-hidden="true">↗</span><h2>Buy enough WIN</h2><p>Meet the live minimum in IMD.</p></div><span className="diagram-arrow" aria-hidden="true">→</span><div><span className="diagram-icon" aria-hidden="true">◷</span><h2>Take the lead</h2><p>Reset the clock to 10 minutes.</p></div><span className="diagram-arrow" aria-hidden="true">→</span><div><span className="diagram-icon" aria-hidden="true">⚑</span><h2>Outlast the clock</h2><p>Anyone settles. The leader wins.</p></div></section>
    <div className="rules-list"><article><span className="rule-number">01 / The bank</span><div><h2>Every trade grows the prize.</h2><p>Buys and sells pay a game fee in IMD: taken from the input on buys and the output on sells. At launch, the fee started at 50% and fell linearly to 3% over 30 minutes. Of that fee, 90% fills the prize bank and 10% is owed to the fixed team wallet. The pool’s separate 0.3% liquidity fee also applies.</p></div></article><article><span className="rule-number">02 / The lead</span><div><h2>Buy above the minimum. Reset the clock.</h2><p>A buy at or above the minimum makes you the leader and resets the timer to 10 minutes. Sells never change the leader or timer. Only trades through this exact pool participate.</p><p>The minimum starts at the larger of 8.5 IMD and 20% of the round’s current prize. It is multiplied by 1.05 for every qualifying buy already in the round. This multiplier resets each round; it is capped in the contract to prevent overflow. The amount checked is your gross IMD input, including the game fee.</p><div className="formula">Minimum = max(8.5 IMD, 20% of prize) × 1.05ⁿ<span>n = qualifying buys in this round · contract rounding applies</span></div></div></article><article><span className="rule-number">03 / The prize</span><div><h2>The last buyer wins the round.</h2><p>The first round cannot end earlier than three hours after launch and awards 20% of the bank. Every later round awards 5%. The remainder stays in the bank for future rounds. The displayed prize can grow as fees arrive.</p><p>When the timer hits zero, anyone can press Settle. The prize goes to the leader, even if someone else settles. A buy after expiry closes the old round for its winner and can start the next one; it cannot steal the expired round.</p></div></article><article><span className="rule-number">04 / The payout</span><div><h2>Your prize stays yours.</h2><p>Settle tries to pay the winner immediately. If the transfer fails, or a later buy closes the round, the prize becomes a deferred claim. Connect the winning wallet and use Claim prize when the banner appears. The contract always sends that claim to the winner.</p></div></article><article><span className="rule-number">05 / The code</span><div><h2>Fixed rules, from the start.</h2><p>WIN has a fixed supply of 1 billion tokens with 18 decimals. The token and game have no owner, admin keys, mint function after construction, or upgrade mechanism. Nobody can change the game’s rules or withdraw the bank outside those rules. This does not remove trading or contract risk.</p><a href={`${deployment.repoUrl}/tree/${deployment.sourceCommit}`} target="_blank" rel="noreferrer">Read the deployed source <Arrow /></a></div></article></div>
    <section className="contracts-section"><div className="section-heading"><div><p className="eyebrow">Verify, then trust</p><h2>The onchain addresses</h2></div><span className="muted">Robinhood Chain · 4663</span></div><div className="contracts-list">{contracts.map(([label, value]) => <div className="contract-row" key={label}><h3>{label}</h3><AddressLink value={value} full /><CopyButton value={value} label={label} /></div>)}</div><details className="pool-details"><summary>Pool ID and network details</summary><p className="full-address">{poolId}</p><p>WIN / IMD · Uniswap v4 · Fee tier {deployment.manifest.pool.fee} · Tick spacing {deployment.manifest.pool.tickSpacing}</p><p>PoolManager: <AddressLink value={network.uniswapV4.poolManager as Address} full /></p><p>Native gas currency: ETH. Wallet connection uses an injected Ethereum provider. A wallet browser or browser extension is required to transact.</p></details></section>
  </>;
}

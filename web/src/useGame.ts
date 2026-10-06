import { useCallback, useEffect, useRef, useState } from 'react';
import { type Address } from 'viem';
import { addresses, client, hookAbi, readGame, readWinners, verifyDeployment, type Winner } from './chain';
import { errorText } from './format';

export function useGame(account?: Address) {
  const [snapshot, setSnapshot] = useState<Awaited<ReturnType<typeof readGame>>>();
  const [winners, setWinners] = useState<readonly Winner[]>();
  const [historyError, setHistoryError] = useState('');
  const [error, setError] = useState('');
  const [verified, setVerified] = useState(false);
  const [verifyError, setVerifyError] = useState('');
  const [unclaimed, setUnclaimed] = useState(0n);
  const [claimError, setClaimError] = useState('');
  const [now, setNow] = useState(performance.now());
  const [lastSuccess, setLastSuccess] = useState(0);
  const busy = useRef(false);
  const refresh = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      const next = await readGame();
      setSnapshot(old => old?.block === next.block ? old : next);
      setLastSuccess(performance.now()); setError('');
    } catch (e) { setError(`Live data is unavailable. Check your connection or retry. ${errorText(e)}`); }
    finally { busy.current = false; }
  }, []);
  const refreshHistory = useCallback(async () => {
    try { setWinners(await readWinners()); setHistoryError(''); }
    catch { setHistoryError('Winner history could not load. Retry to read the contract again.'); }
  }, []);
  const verify = useCallback(async () => {
    setVerifyError('');
    try { await verifyDeployment(); setVerified(true); }
    catch (e) { setVerified(false); setVerifyError(errorText(e)); }
  }, []);
  useEffect(() => { void verify(); }, [verify]);
  useEffect(() => {
    void refresh();
    const poll = setInterval(() => { void refresh(); }, 5000);
    const tick = setInterval(() => setNow(performance.now()), 1000);
    return () => { clearInterval(poll); clearInterval(tick); };
  }, [refresh]);
  useEffect(() => { void refreshHistory(); }, [snapshot?.state.winners, refreshHistory]);
  useEffect(() => {
    let active = true; setUnclaimed(0n); setClaimError('');
    if (account) client.readContract({ address: addresses.hook, abi: hookAbi, functionName: 'unclaimedPrize', args: [account] })
      .then(value => { if (active) setUnclaimed(value); })
      .catch(() => { if (active) setClaimError('Could not check your deferred prize. Retry live data to check again.'); });
    return () => { active = false; };
  }, [account, snapshot]);
  const stale = !!error || (lastSuccess > 0 && now - lastSuccess > 20_000) || (!!snapshot && now - snapshot.receivedAt > 30_000);
  return { snapshot, winners, historyError, error, verified, verifyError, unclaimed, claimError, now, stale, refresh, refreshHistory, verify };
}

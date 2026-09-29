import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { open, stat, statfs, mkdir, rename, rm } from 'node:fs/promises';
import { dirname } from 'node:path';
export interface Asset { url: string; size: number; sha256: string; revision: string; id: string }
export interface DownloadProgress { phase: string; received: number; total: number; error?: string }
export function ensureSpace(available: number, needed: number) { if (available < needed + 128 * 1024 * 1024) throw new Error('For lite ledig diskplass. Frigjør minst 650 MB og prøv igjen.'); }
export async function checksum(path: string) { const hash = createHash('sha256'); for await (const chunk of createReadStream(path)) hash.update(chunk); return hash.digest('hex'); }
export async function verified(path: string, asset: Asset) { try { return (await stat(path)).size === asset.size && await checksum(path) === asset.sha256; } catch { return false; } }
export async function downloadAsset(asset: Asset, destination: string, signal: AbortSignal, progress: (p: DownloadProgress) => void, fetcher: typeof fetch = fetch) {
  if (!asset.url.startsWith('https://')) throw new Error('Nedlasting krever HTTPS.');
  await mkdir(dirname(destination), { recursive: true });
  if (await verified(destination, asset)) return;
  const partial = `${destination}.partial`;
  let offset = await stat(partial).then(s => s.size).catch(() => 0);
  if (offset > asset.size) { await rm(partial, { force: true }); offset = 0; }
  const disk = await statfs(dirname(destination));
  ensureSpace(disk.bavail * disk.bsize, asset.size - offset);
  if (offset < asset.size) {
    const network = new AbortController();
    let timeout = setTimeout(() => network.abort(), 60000);
    const resetTimeout = () => { clearTimeout(timeout); timeout = setTimeout(() => network.abort(), 60000); };
    try {
    let response: Response;
    try { response = await fetcher(asset.url, { headers: offset ? { Range: `bytes=${offset}-`, 'Accept-Encoding': 'identity' } : { 'Accept-Encoding': 'identity' }, signal: AbortSignal.any([signal, network.signal]) }); }
    catch (error) { if (signal.aborted) throw error; throw new Error('Nedlastingen kunne ikke starte. Kontroller internett og prøv igjen. NTNU VPN er ikke nødvendig.'); }
    if (!response.ok || !response.body) throw new Error(`Nedlasting feilet (HTTP ${response.status}). Prøv igjen.`);
    if (response.status === 206) {
      const range = response.headers.get('content-range');
      if (!range || !range.startsWith(`bytes ${offset}-`) || !range.endsWith(`/${asset.size}`)) throw new Error('Serveren svarte med et ugyldig filområde. Avbryt og prøv igjen.');
    } else { offset = 0; }
    const file = await open(partial, offset ? 'a' : 'w');
    try {
      progress({ phase: 'downloading', received: offset, total: asset.size });
      const reader = response.body.getReader();
      while (true) {
        signal.throwIfAborted();
        const { done, value } = await reader.read(); if (done) break; resetTimeout();
        if (offset + value.length > asset.size) throw new Error('Nedlastingen er større enn forventet. Avbryt og prøv igjen.');
        let written = 0; while (written < value.length) written += (await file.write(value.subarray(written))).bytesWritten;
        offset += value.length; progress({ phase: 'downloading', received: offset, total: asset.size });
      }
      await file.sync();
    } finally { await file.close(); }
    } catch (error) {
      if (signal.aborted) throw error;
      if (network.signal.aborted) throw new Error('Nedlastingen stoppet fordi nettverket ikke svarte på 60 sekunder. Prøv igjen for å fortsette.');
      throw error;
    } finally { clearTimeout(timeout); network.abort(); }
  }
  signal.throwIfAborted(); progress({ phase: 'verifying', received: offset, total: asset.size });
  if (!await verified(partial, asset)) { await rm(partial, { force: true }); throw new Error('Kontrollsummen stemmer ikke. Den ufullstendige filen er fjernet. Prøv igjen.'); }
  signal.throwIfAborted(); await rename(partial, destination);
}

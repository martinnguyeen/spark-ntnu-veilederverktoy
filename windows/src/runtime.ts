import { mkdir, readFile, readdir, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import manifest from '../../docs/shared-contracts/model-manifest.json';
import { checksum, downloadAsset, DownloadProgress, verified } from './download';
import { run } from './process';
import { atomicWrite } from './storage';
export class Runtime {
  controller?: AbortController;
  task?: Promise<void>;
  progress: DownloadProgress = { phase: 'checking', received: 0, total: 0 };
  ready = false;
  readonly model: string; readonly archive: string; readonly directory: string;
  executable = '';
  private verifiedFiles = new Map<string, string>();
  private async fingerprint(path: string) { const s = await stat(path); return `${s.size}:${s.mtimeMs}:${s.ctimeMs}`; }
  async ensureReady() {
    if (!this.ready) throw new Error('Whisper er ikke klar. Kontroller filene i innstillingene.');
    for (const [file, signature] of this.verifiedFiles) {
      if (await this.fingerprint(file).catch(() => '') !== signature) {
        if (!await this.check()) { this.update({ phase: 'error', received: 0, total: 0, error: 'Lokale Whisper-filer er endret eller skadet. Velg Reparer.' }); throw new Error('Whisper-filene kunne ikke verifiseres. Velg Reparer før transkripsjon.'); }
        return;
      }
    }
  }
  constructor(readonly root: string, readonly emit: (p: DownloadProgress) => void) {
    this.model = join(root, 'Models', manifest.model.revision, 'ggml-model.bin');
    this.directory = join(root, 'Runtime', manifest.runtime.revision);
    this.archive = join(root, 'Runtime', `${manifest.runtime.revision}.zip`);
  }
  update(p: DownloadProgress) { this.progress = p; this.emit(p); }
  async files(folder: string): Promise<string[]> { const entries = await readdir(folder, { withFileTypes: true }); return (await Promise.all(entries.map(e => e.isDirectory() ? this.files(join(folder, e.name)) : [join(folder, e.name)]))).flat(); }
  async check() {
    this.ready = false;
    this.verifiedFiles.clear();
    if (!await verified(this.model, manifest.model) || !await verified(this.archive, manifest.runtime)) return false;
    try {
      const hashes = JSON.parse(await readFile(join(this.directory, 'verified-files.json'), 'utf8')) as Record<string, string>;
      const files = (await this.files(this.directory)).filter(f => f !== join(this.directory, 'verified-files.json'));
      if (!files.length || files.length !== Object.keys(hashes).length) return false;
      for (const file of files) if (await checksum(file) !== hashes[file.slice(this.directory.length + 1)]) return false;
      this.executable = files.find(f => /[\\/]whisper-cli.exe$/i.test(f)) ?? '';
      for (const file of [this.model, this.archive, ...files]) this.verifiedFiles.set(file, await this.fingerprint(file));
      this.ready = !!this.executable; return this.ready;
    } catch { return false; }
  }
  start() {
    if (this.task) return this.task;
    this.controller = new AbortController();
    this.task = this.install(this.controller.signal).catch(e => {
      this.update({ ...this.progress, phase: this.controller?.signal.aborted ? 'paused' : 'error', error: this.controller?.signal.aborted ? undefined : (e as Error).message });
    }).finally(() => { this.task = undefined; this.controller = undefined; });
    return this.task;
  }
  async pause() { this.controller?.abort(); await this.task; }
  async cancel() { await this.pause(); await Promise.all([rm(`${this.model}.partial`, { force: true }), rm(`${this.archive}.partial`, { force: true })]); const ready = await this.check(); this.update({ phase: ready ? 'ready' : 'missing', received: 0, total: 0 }); }
  async removeModel() { await this.pause(); this.ready = false; await rm(this.model, { force: true }); await rm(`${this.model}.partial`, { force: true }); this.update({ phase: 'missing', received: 0, total: 0 }); }
  private async install(signal: AbortSignal) {
    if (await this.check()) { this.update({ phase: 'ready', received: 0, total: 0 }); return; }
    await downloadAsset(manifest.runtime, this.archive, signal, p => this.update({ ...p, phase: `runtime-${p.phase}` }));
    signal.throwIfAborted();
    await rm(this.directory, { recursive: true, force: true }); await mkdir(this.directory, { recursive: true });
    // Windows 11 includes bsdtar. Argument arrays avoid shell quoting and profiles.
    await run(join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe'), ['-xf', this.archive, '-C', this.directory], 120000);
    const hashes: Record<string, string> = {};
    for (const file of await this.files(this.directory)) hashes[file.slice(this.directory.length + 1)] = await checksum(file);
    await atomicWrite(join(this.directory, 'verified-files.json'), JSON.stringify(hashes));
    await downloadAsset(manifest.model, this.model, signal, p => this.update(p));
    if (!await this.check()) throw new Error('Runtime kunne ikke verifiseres. Velg Reparer og prøv igjen.');
    this.update({ phase: 'ready', received: manifest.model.size, total: manifest.model.size });
  }
}

import { open, readFile, readdir, rm, statfs, stat } from 'node:fs/promises';
import { markAudioCompleted } from './retention';
import { join } from 'node:path';
import { availableParallelism } from 'node:os';
import { Runtime } from './runtime';
import { Repository, atomicWrite } from './storage';
import { Meeting, whisperSegments } from './domain';
import { run } from './process';
export function wavHeader(bytes: number) {
  if (bytes > 0xffffffff - 36) throw new Error('Opptaket er for langt for WAV-formatet.');
  const b = Buffer.alloc(44); b.write('RIFF'); b.writeUInt32LE(bytes + 36, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(bytes, 40); return b;
}
export function pcmBuffer(samples: Float32Array) { const b = Buffer.alloc(samples.length * 2); for (let i = 0; i < samples.length; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, Number.isFinite(samples[i]) ? samples[i] : 0)) * 32767), i * 2); return b; }
export class AudioService {
  active?: Meeting; busy = false; private live: Promise<void> = Promise.resolve(); private writing = Promise.resolve(); private next = 0; private livePending = 0;
  constructor(readonly repo: Repository, readonly runtime: Runtime, readonly emit: (channel: string, data: unknown) => void) {}
  async start(dictation: boolean) {
    if (this.active || this.busy) throw new Error('Et opptak eller en transkripsjon pågår allerede.');
    if (!this.runtime.ready) throw new Error('Gjør lokal transkripsjon klar i innstillingene først.');
    this.busy = true;
    try {
    await this.requireSpace(0);
    this.active = await this.repo.create(dictation ? 'Hurtigdiktering' : `Møte ${new Date().toLocaleDateString('nb-NO')}`);
    this.active.state = 'recording'; this.next = 0; this.livePending = 0;
    try { await this.repo.save(this.active); return this.active; }
    catch (error) { this.active = undefined; throw error; }
    } finally { this.busy = false; }
  }
  private async requireSpace(bytes: number) {
    const disk = await statfs(this.runtime.root);
    if (disk.bavail * disk.bsize < bytes + 128 * 1024 * 1024) throw new Error('For lite ledig diskplass til opptaket. Frigjør plass. Avsluttede lydsegmenter er bevart.');
  }
  chunk(id: string, samples: Float32Array) {
    if (!this.active || id !== this.active.id || !(samples instanceof Float32Array) || samples.length < 1 || samples.length > 16000 * 30) throw new Error('Ugyldig lydsegment.');
    const meeting = this.active; const index = this.next++; const offset = meeting.duration;
    meeting.duration += samples.length / 16000;
    const path = join(this.repo.folder(id), `segment-${index.toString().padStart(6, '0')}.wav`);
    const pcm = pcmBuffer(samples);
    const work = this.writing.then(async () => { await this.requireSpace(pcm.length); await atomicWrite(path, Buffer.concat([wavHeader(pcm.length), pcm])); await this.repo.save(meeting); });
    this.writing = work.catch(() => {});
    // Do not queue unbounded Whisper jobs when CPU transcription is slower than capture.
    if (this.livePending < 1) {
      this.livePending++;
      this.live = work.then(async () => {
        const segments = await this.transcribe(path, offset, `live${index}-`);
        meeting.transcript.push(...segments); await this.repo.save(meeting); this.emit('live', meeting);
      }).catch(() => this.emit('status', 'Foreløpig tekst er ikke tilgjengelig. Lydsegmentene beholdes for full transkripsjon.')).finally(() => { this.livePending--; });
    }
    return work;
  }
  async transcribe(path: string, offset = 0, prefix = 's') {
    if (!this.runtime.ready) throw new Error('Whisper er ikke klar. Åpne innstillingene.');
    await this.runtime.ensureReady();
    const output = `${path}.transcript`;
    try {
      await run(this.runtime.executable, ['-m', this.runtime.model, '-f', path, '-l', 'no', '-oj', '-of', output, '-np', '-ng', '-t', String(Math.max(1, Math.min(8, availableParallelism() - 1)))], 2 * 60 * 60 * 1000);
      return whisperSegments(JSON.parse(await readFile(`${output}.json`, 'utf8')), offset, prefix);
    } finally { await rm(`${output}.json`, { force: true }); }
  }
  async combine(id: string) {
    const folder = this.repo.folder(id); const segments = (await readdir(folder)).filter(f => /^segment-\d{6}\.wav$/.test(f)).sort();
    if (!segments.length) throw new Error('Ingen avsluttede lydsegmenter å gjenopprette.');
    const size = (await Promise.all(segments.map(name => stat(join(folder, name))))).reduce((sum, s) => sum + s.size, 0);
    await this.requireSpace(size);
    const path = join(folder, 'recording.wav'); const temp = `${path}.tmp`; const out = await open(temp, 'w'); let bytes = 0;
    try {
      await out.writeFile(wavHeader(0));
      for (const name of segments) {
        const b = await readFile(join(folder, name));
        if (b.length < 44 || b.toString('ascii', 0, 4) !== 'RIFF' || b.readUInt32LE(24) !== 16000 || b.readUInt16LE(22) !== 1 || b.readUInt32LE(40) !== b.length - 44) throw new Error(`Lydsegment ${name} er skadet. Originalfilene er bevart.`);
        const pcm = b.subarray(44); await out.writeFile(pcm); bytes += pcm.length;
      }
      await out.write(wavHeader(bytes), 0, 44, 0); await out.sync();
    } finally { await out.close(); }
    const { rename } = await import('node:fs/promises'); await rename(temp, path); return { path, duration: bytes / 32000 };
  }
  async finish(id: string) {
    if (this.busy) throw new Error('Vent til gjeldende oppgave er ferdig.');
    this.busy = true;
    try {
      await this.writing; await this.live;
      const m = this.active?.id === id ? this.active : await this.repo.load(id);
      if (this.active && this.active.id !== id) throw new Error('Et annet opptak pågår.');
      this.active = undefined; m.state = 'transcribing'; await this.repo.save(m); this.emit('changed', null);
      const { path, duration } = await this.combine(id); m.duration = duration;
      m.transcript = await this.transcribe(path); if (!m.transcript.length) throw new Error('Ingen tale funnet. Opptaket er bevart; prøv igjen.');
      m.state = 'transcriptReady'; m.analysis = null; await this.repo.save(m);
      await markAudioCompleted(this.repo, id).catch(() => this.emit('status', 'Transkripsjonen er lagret. Automatisk rålydsletting kunne ikke planlegges; slett møtelyden manuelt ved behov.'));
      return m;
    } finally { this.busy = false; this.emit('changed', null); }
  }
  async abandonStart() {
    await this.writing; await this.live;
    if (this.active) { const m = this.active; this.active = undefined; m.state = 'finalizing'; await this.repo.save(m); }
  }
  async cancel() {
    await this.writing; await this.live;
    if (this.active) { const id = this.active.id; this.active = undefined; await this.repo.delete(id); }
  }
  async importPCM(title: string, samples: Float32Array) {
    if (!(samples instanceof Float32Array) || !samples.length || samples.length > 16000 * 60 * 120) throw new Error('Lydimport krever lyd og er begrenset til to timer.');
    const m = await this.start(false); m.title = title.slice(0, 500);
    // Persist independent chunks for recovery, without starting provisional jobs for imports.
    this.livePending++;
    try {
      try { for (let i = 0; i < samples.length; i += 16000 * 15) await this.chunk(m.id, samples.slice(i, i + 16000 * 15)); }
      finally { this.livePending--; }
      return await this.finish(m.id);
    } catch (error) { await this.abandonStart().catch(() => {}); throw error; }
  }
}

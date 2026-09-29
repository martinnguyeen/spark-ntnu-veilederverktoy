import { readFile, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { Repository, atomicWrite } from './storage';
const audioFile = /^(segment-\d{6}\.wav|recording\.wav)(\.tmp|\.transcript\.json)?$/;
export async function markAudioCompleted(repo: Repository, id: string, now = Date.now()) {
  await atomicWrite(join(repo.folder(id), 'audio-retention.json'), JSON.stringify({ version: 1, completedAt: now, deleteAfter: now + 7 * 24 * 60 * 60 * 1000 }));
}
export async function enforceRetention(repo: Repository, now = Date.now()) {
  let removed = 0;
  for (const meeting of (await repo.list()).meetings) {
    if (!['transcriptReady', 'completed', 'completedWithoutAnalysis'].includes(meeting.state) || !meeting.transcript.length) continue;
    try {
      const folder = repo.folder(meeting.id);
      const meta = JSON.parse(await readFile(join(folder, 'audio-retention.json'), 'utf8'));
      if (meta.version !== 1 || !Number.isFinite(meta.completedAt) || meta.deleteAfter !== meta.completedAt + 604800000 || meta.deleteAfter > now) continue;
      for (const name of await readdir(folder)) if (audioFile.test(name)) await rm(join(folder, name), { force: true });
      await rm(join(folder, 'audio-retention.json')); removed++;
    } catch { /* Invalid/missing metadata is preserved; never infer an expiry. */ }
  }
  return removed;
}

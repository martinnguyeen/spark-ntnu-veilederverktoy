import { mkdir, readFile, open, rename, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Meeting, validateMeeting, validID } from './domain';
export async function atomicWrite(path: string, data: string | Uint8Array) {
  const temp = `${path}.${randomUUID()}.tmp`;
  try { const file = await open(temp, 'w', 0o600); try { await file.writeFile(data); await file.sync(); } finally { await file.close(); } await rename(temp, path); }
  finally { await rm(temp, { force: true }); }
}
export class Repository {
  constructor(readonly root: string) {}
  folder(id: string) { validID(id); return join(this.root, id.toUpperCase()); }
  async load(id: string): Promise<Meeting> { return validateMeeting(JSON.parse(await readFile(join(this.folder(id), 'meeting.json'), 'utf8'))); }
  async list(): Promise<{ meetings: Meeting[]; unreadable: number }> {
    await mkdir(this.root, { recursive: true }); const meetings: Meeting[] = []; let unreadable = 0;
    for (const entry of await readdir(this.root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      try { meetings.push(await this.load(entry.name)); } catch { unreadable++; }
    }
    return { meetings: meetings.sort((a, b) => b.date.localeCompare(a.date)), unreadable };
  }
  async save(meeting: Meeting) { validateMeeting(meeting); await mkdir(this.folder(meeting.id), { recursive: true }); await atomicWrite(join(this.folder(meeting.id), 'meeting.json'), JSON.stringify(meeting, null, 2)); }
  async delete(id: string) { await rm(this.folder(id), { recursive: true, force: true }); }
  async create(title: string): Promise<Meeting> {
    const meeting: Meeting = { id: randomUUID().toUpperCase(), title, date: new Date().toISOString(), duration: 0, state: 'idle', transcript: [] };
    await this.save(meeting); return meeting;
  }
}

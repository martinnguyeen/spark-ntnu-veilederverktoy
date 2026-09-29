import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { downloadAsset, verified, Asset, ensureSpace } from '../src/download';
import { Repository } from '../src/storage';
import { validateAnalysis, validateMeeting, markdown, whisperSegments, searchMeeting, validID, Meeting, Analysis, baseEntry } from '../src/domain';
import { markAudioCompleted, enforceRetention } from '../src/retention';
import { pcmBuffer, wavHeader, AudioService } from '../src/audio';
import { Runtime } from '../src/runtime';
import { readTextDocument, textSegments } from '../src/import';
import { analyze, testConnection, endpoint, route, models } from '../src/idun';
const segment = { id: 's1', start: 0, end: 3, speaker: 'Martin', text: 'Vi bestemmer å sende utkast før fredag.' };
const fixture: Meeting = { id: 'D1C4D4D1-8780-4812-94D0-B46CFA709C2C', title: 'Veiledning', date: '2026-09-24T10:00:00Z', duration: 3, state: 'completed', transcript: [segment] };
const analysis: Analysis = { schema_version: '1.0', summary: 'Utkastet sendes fredag.', key_points: [{ text: 'Utkast diskutert', confidence: 'high', evidence_segment_ids: ['s1'] }], decisions: [{ text: 'Send utkast', confidence: 'high', evidence_segment_ids: ['s1'] }], action_items: [{ task: 'Send utkast', owner: null, deadline: 'Fredag', confidence: 'high', evidence_segment_ids: ['s1'] }], open_questions: [] };
async function temp<T>(fn: (dir: string) => Promise<T>) { const dir = await mkdtemp(join(tmpdir(), 'spark-unit-')); try { return await fn(dir); } finally { await rm(dir, { recursive: true, force: true }); } }
const payload = Buffer.from('test asset contents');
const asset: Asset = { id: 'test', revision: '1', url: 'https://example.test/model', size: payload.length, sha256: createHash('sha256').update(payload).digest('hex') };
const signal = () => new AbortController().signal;

test('model is only promoted after checksum verification; valid installs do not fetch again', () => temp(async dir => {
  const path = join(dir, 'model'); const seen: number[] = [];
  await downloadAsset(asset, path, signal(), p => seen.push(p.received), async () => new Response(payload));
  assert.equal(await verified(path, asset), true); assert.ok(seen.includes(payload.length));
  await downloadAsset(asset, path, signal(), () => {}, async () => { throw new Error('Unexpected network'); });
}));
test('corrupt model is rejected and partial removed', () => temp(async dir => {
  const path = join(dir, 'model');
  await assert.rejects(downloadAsset(asset, path, signal(), () => {}, async () => new Response(Buffer.alloc(payload.length))), /Kontrollsummen/);
  await assert.rejects(stat(path)); await assert.rejects(stat(`${path}.partial`));
}));
test('resumes from saved bytes and validates Content-Range', () => temp(async dir => {
  const path = join(dir, 'model'); await writeFile(`${path}.partial`, payload.subarray(0, 4));
  await downloadAsset(asset, path, signal(), () => {}, async (_url, options) => {
    assert.equal(new Headers(options?.headers).get('range'), 'bytes=4-');
    return new Response(payload.subarray(4), { status: 206, headers: { 'Content-Range': `bytes 4-${payload.length - 1}/${payload.length}` } });
  }); assert.deepEqual(await readFile(path), payload);
}));
test('server ignoring Range restarts safely', () => temp(async dir => {
  const path = join(dir, 'model'); await writeFile(`${path}.partial`, payload.subarray(0, 4));
  await downloadAsset(asset, path, signal(), () => {}, async () => new Response(payload)); assert.deepEqual(await readFile(path), payload);
}));
test('incorrect Content-Range never accepted', () => temp(async dir => {
  await assert.rejects(downloadAsset(asset, join(dir, 'model'), signal(), () => {}, async () => new Response(payload, { status: 206, headers: { 'Content-Range': 'bytes 3-7/8' } })), /filområde/);
}));
test('pause leaves partial data and never installs it', () => temp(async dir => {
  const controller = new AbortController(); const path = join(dir, 'model');
  const stream = new ReadableStream({ start(c) { c.enqueue(payload.subarray(0, 4)); }, cancel() {} });
  await assert.rejects(downloadAsset(asset, path, controller.signal, p => { if (p.received === 4) controller.abort(); }, async () => new Response(stream)));
  assert.equal((await stat(`${path}.partial`)).size, 4); await assert.rejects(stat(path));
}));
test('HTTP and offline failures are actionable', () => temp(async dir => {
  await assert.rejects(downloadAsset(asset, join(dir, 'model'), signal(), () => {}, async () => new Response('', { status: 503 })), /HTTP 503/);
  await assert.rejects(downloadAsset(asset, join(dir, 'model'), signal(), () => {}, async () => { throw new Error('offline'); }), /internett/);
}));
test('non HTTPS sources are rejected', () => temp(async dir => {
  await assert.rejects(downloadAsset({ ...asset, url: 'http://example.test/model' }, join(dir, 'model'), signal(), () => {}), /HTTPS/);
}));
test('insufficient disk space is rejected before network download', () => {
  assert.throws(() => ensureSpace(10_000_000, 487601984), /diskplass/);
  assert.doesNotThrow(() => ensureSpace(1024 ** 3, 487601984));
});
test('Mac-shaped meeting JSON roundtrips; local delete removes only selected meeting', () => temp(async dir => {
  const repo = new Repository(dir); await repo.save({ ...fixture, analysis });
  assert.deepEqual(await repo.load(fixture.id), { ...fixture, analysis });
  const second = await repo.create('Andre møte'); await repo.delete(fixture.id); assert.equal((await repo.list()).meetings[0].id, second.id);
  assert.throws(() => repo.folder('../escape')); assert.throws(() => validID('C:\\private'));
}));
test('corrupt records are counted, not deleted', () => temp(async dir => {
  const repo = new Repository(dir); const m = await repo.create('Test'); await writeFile(join(repo.folder(m.id), 'meeting.json'), '{broken');
  assert.equal((await repo.list()).unreadable, 1); assert.ok(await stat(join(repo.folder(m.id), 'meeting.json')));
}));
test('analysis rejects missing evidence and filters tentative decisions', () => {
  assert.throws(() => validateAnalysis({ ...analysis, decisions: [{ text: 'invented', confidence: 'high', evidence_segment_ids: ['unknown'] }] }, [segment]), /kildeutsagn/);
  assert.throws(() => validateAnalysis({ ...analysis, action_items: [{ ...analysis.action_items[0], evidence_segment_ids: [] }] }, [segment]));
  assert.equal(validateAnalysis(analysis, [{ ...segment, text: 'Kanskje vi bør sende utkast.' }]).decisions.length, 0);
});
test('Whisper offsets are milliseconds; search and export preserve Norwegian', () => {
  assert.equal(whisperSegments({ transcription: [{ offsets: { from: 1200, to: 3000 }, text: ' Hei ' }] }, 15)[0].start, 16.2);
  assert.equal(searchMeeting({ ...fixture, analysis }, 'FREDAG'), true);
  assert.match(markdown({ ...fixture, analysis }), /## Gjøremål/);
  assert.throws(() => validateMeeting({ ...fixture, transcript: [{ ...segment, end: -1 }] }));
});
test('PCM normalization produces 16 kHz mono signed little endian WAV', () => {
  const pcm = pcmBuffer(new Float32Array([-2, 0, 2, NaN])); assert.equal(pcm.readInt16LE(0), -32767); assert.equal(pcm.readInt16LE(4), 32767); assert.equal(pcm.readInt16LE(6), 0);
  const header = wavHeader(pcm.length); assert.equal(header.readUInt32LE(24), 16000); assert.equal(header.readUInt16LE(22), 1); assert.equal(header.readUInt32LE(40), 8);
});
test('IDUN requires explicit consent and sends only transcript/metadata to fixed endpoint', async () => {
  let calls = 0;
  const fetcher: typeof fetch = async (url, options) => {
    calls++; assert.equal(url, endpoint); assert.equal(options?.redirect, 'error');
    const body = JSON.parse(options?.body as string); assert.ok(body.messages[1].content.includes(segment.text)); assert.equal(JSON.stringify(body).includes('audio'), false);
    assert.equal(new Headers(options?.headers).get('authorization'), 'Bearer test-key');
    return Response.json({ choices: [{ message: { content: JSON.stringify(analysis) }, finish_reason: 'stop' }] });
  };
  await assert.rejects(analyze(fixture, 'test-key', false, false, resolve('../docs/shared-contracts'), () => {}, fetcher), /bekreftelse/); assert.equal(calls, 0);
  assert.deepEqual(await analyze(fixture, 'test-key', false, true, resolve('../docs/shared-contracts'), () => {}, fetcher), analysis); assert.equal(calls, 1);
});
test('connection test contains no meeting data and never exposes keys in errors', async () => {
  await assert.rejects(testConnection('secret-test-key', async (_url, options) => { assert.equal((options?.body as string).includes(segment.text), false); return new Response('secret-test-key', { status: 401 }); }), e => e instanceof Error && !e.message.includes('secret-test-key') && e.message.includes('avvist'));
  assert.equal(route(1000, false)[0], models.mistral); assert.equal(route(25000, true)[0], models.borealis); assert.throws(() => route(180000, false));
});
test('closed WAV segments survive a fresh service and can be recovered', () => temp(async dir => {
  const repo = new Repository(join(dir, 'Meetings')); const runtime = new Runtime(dir, () => {}); runtime.ready = true;
  const first = new AudioService(repo, runtime, () => {}); first.transcribe = async () => [segment];
  const meeting = await first.start(false); await first.chunk(meeting.id, new Float32Array(16000).fill(0.25)); await first.abandonStart();
  const recovered = new AudioService(repo, runtime, () => {});
  recovered.transcribe = async path => { const b = await readFile(path); assert.equal(b.readUInt32LE(40), 32000); return [segment]; };
  const result = await recovered.finish(meeting.id); assert.equal(result.state, 'transcriptReady'); assert.equal(result.duration, 1); assert.equal(result.transcript[0].text, segment.text);
}));
test('cancel deletes temporary audio and releases active recording', () => temp(async dir => {
  const repo = new Repository(join(dir, 'Meetings')); const runtime = new Runtime(dir, () => {}); runtime.ready = true;
  const service = new AudioService(repo, runtime, () => {}); service.transcribe = async () => [segment];
  const m = await service.start(true); await service.chunk(m.id, new Float32Array(100)); await service.cancel();
  assert.equal(service.active, undefined); await assert.rejects(stat(repo.folder(m.id)));
}));
test('text import preserves speakers and Windows-1252 Norwegian characters', () => temp(async dir => {
  const path = join(dir, 'text.txt'); await writeFile(path, Buffer.from([0x53, 0xf8, 0x6b]));
  assert.equal(await readTextDocument(path), 'Søk');
  const segments = textSegments('Speaker 1: Hei\n\nSpeaker 2: God dag'); assert.equal(segments[1].speaker, 'Speaker 2'); assert.equal(segments[1].text, 'God dag');
}));
test('RTF import uses local Windows text extraction', { skip: process.platform !== 'win32' }, () => temp(async dir => {
  const path = join(dir, 'test.rtf'); await writeFile(path, '{\\rtf1\\ansi Hei fra m\\u248?tet.}');
  assert.equal((await readTextDocument(path)).trim(), 'Hei fra møtet.');
}));
test('a failed import releases the recording lock and retains closed audio', () => temp(async dir => {
  class FailingRepository extends Repository {
    saves = 0;
    override async save(m: Meeting) { if (++this.saves >= 3) throw new Error('ENOSPC'); await super.save(m); }
  }
  const repo = new FailingRepository(join(dir, 'Meetings')); const runtime = new Runtime(dir, () => {}); runtime.ready = true;
  const audio = new AudioService(repo, runtime, () => {});
  await assert.rejects(audio.importPCM('Test', new Float32Array(16000)), /ENOSPC/);
  assert.equal(audio.active, undefined); assert.equal(audio.busy, false);
  const m = (await repo.list()).meetings[0]; assert.ok(await stat(join(repo.folder(m.id), 'segment-000000.wav')));
}));
test('Mac Codable optional fields and legacy point text import without inventing certainty', () => {
  const imported = structuredClone({ ...fixture, analysis }) as any;
  delete imported.analysis.action_items[0].owner; delete imported.analysis.action_items[0].deadline;
  delete imported.analysis.key_points[0].confidence;
  imported.analysis.key_points[0].point = imported.analysis.key_points[0].text; delete imported.analysis.key_points[0].text;
  const result = validateMeeting(imported);
  assert.equal(result.analysis!.action_items[0].owner, null);
  assert.equal(result.analysis!.key_points[0].confidence, undefined);
  assert.equal(result.analysis!.key_points[0].text, 'Utkast diskutert');
  assert.throws(() => validateAnalysis(imported.analysis, fixture.transcript), /sikkerhetsnivå/);
});
test('archived decisions are not silently changed when a meeting is reopened', () => {
  const m = { ...fixture, transcript: [{ ...segment, text: 'Kanskje vi bør sende utkast.' }], analysis };
  assert.equal(validateMeeting(m).analysis!.decisions.length, 1);
  assert.equal(validateAnalysis(analysis, m.transcript).decisions.length, 0);
});
test('base copy matches Mac sections and excludes low-confidence actions and raw transcript', () => {
  const text = baseEntry({ ...fixture, analysis: { ...analysis, action_items: [...analysis.action_items, { ...analysis.action_items[0], task: 'Tentativt forslag', confidence: 'low' }] } });
  assert.match(text, /Dette ble diskutert/); assert.match(text, /To-Do/); assert.doesNotMatch(text, /Tentativt forslag|Transkripsjon|\[00:00\]/);
});
test('retention expires only completed raw audio and preserves meeting text and unrelated files', () => temp(async dir => {
  const repo = new Repository(dir); await repo.save(fixture); const folder = repo.folder(fixture.id);
  await writeFile(join(folder, 'recording.wav'), 'audio'); await writeFile(join(folder, 'segment-000000.wav'), 'audio'); await writeFile(join(folder, 'keep.txt'), 'keep');
  await markAudioCompleted(repo, fixture.id, 1000);
  assert.equal(await enforceRetention(repo, 1000 + 604799999), 0);
  assert.equal(await enforceRetention(repo, 1000 + 604800000), 1);
  assert.deepEqual(await repo.load(fixture.id), fixture); assert.equal(await readFile(join(folder, 'keep.txt'), 'utf8'), 'keep'); await assert.rejects(stat(join(folder, 'recording.wav')));
}));
test('interrupted recordings and invalid retention manifests never expire', () => temp(async dir => {
  const repo = new Repository(dir); await repo.save({ ...fixture, state: 'transcribing' }); await markAudioCompleted(repo, fixture.id, 0);
  const file = join(repo.folder(fixture.id), 'recording.wav'); await writeFile(file, 'audio');
  assert.equal(await enforceRetention(repo, 999999999), 0); assert.ok(await stat(file));
  await repo.save(fixture); await writeFile(join(repo.folder(fixture.id), 'audio-retention.json'), '{"version":1,"completedAt":0,"deleteAfter":1}');
  assert.equal(await enforceRetention(repo, 999999999), 0); assert.ok(await stat(file));
}));
test('concurrent starts cannot create two active captures', () => temp(async dir => {
  const repo = new Repository(join(dir, 'Meetings')); const runtime = new Runtime(dir, () => {}); runtime.ready = true;
  const audio = new AudioService(repo, runtime, () => {}); const results = await Promise.allSettled([audio.start(false), audio.start(false)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1); assert.equal((await repo.list()).meetings.length, 1); await audio.cancel();
}));
test('damaged closed audio is rejected during recovery instead of silently concatenated', () => temp(async dir => {
  const repo = new Repository(join(dir, 'Meetings')); const runtime = new Runtime(dir, () => {}); runtime.ready = true;
  const audio = new AudioService(repo, runtime, () => {}); audio.transcribe = async () => [segment];
  const m = await audio.start(false); await audio.chunk(m.id, new Float32Array(16000)); await audio.abandonStart();
  await writeFile(join(repo.folder(m.id), 'segment-000000.wav'), 'broken');
  await assert.rejects(audio.finish(m.id), /skadet/); assert.equal(audio.busy, false); assert.equal(await readFile(join(repo.folder(m.id), 'segment-000000.wav'), 'utf8'), 'broken');
}));

import { Meeting, Segment, Evidence, Action, searchMeeting, time, baseEntry } from './domain';
import type { DownloadProgress } from './download';
declare global { interface Window { spark: Record<string, (...args: any[]) => Promise<any>> & { on: (channel: string, cb: (data: any) => void) => () => void } } }
const api = window.spark;
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const input = (id: string) => $<HTMLInputElement>(id);
const settings = $<HTMLDialogElement>('settings');
let meetings: Meeting[] = []; let selected = ''; let ready = false; let busy = false; let operation = ''; let operationStarted = 0;
let detailTab = 'notes'; let startupChecked = false;
let recording: { id: string; dictation: boolean; started: number } | undefined;
let context: AudioContext | undefined; let worklet: AudioWorkletNode | undefined; let streams: MediaStream[] = []; let chunkQueue = Promise.resolve(); let captureFailed = false; let stopping = false;
let flushResolve: (() => void) | undefined;
const escape = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
function message(text: string) { const clean = text.replace(/^Error invoking remote method '[^']+': Error: /, ''); $('status-text').textContent = clean; $('status').hidden = false; if (settings.open) { $('settings-message').textContent = clean; $('settings-message').hidden = false; } }
async function task(fn: () => Promise<void>) { try { await fn(); } catch (e) { message((e as Error).message); } }
function bind(id: string, fn: () => Promise<void> | void) { $(id).addEventListener('click', () => void task(async () => { await fn(); })); }
function setBusy(value: boolean, text = '') { busy = value; operation = text; operationStarted = Date.now(); controls(); renderDetail(); }
function controls() {
  for (const id of ['import-text', 'import-audio', 'dictate', 'analysis-mode']) ($<HTMLButtonElement>(id)).disabled = busy || !!recording;
  $<HTMLButtonElement>('record').disabled = busy;
  document.querySelectorAll<HTMLInputElement>('input[name=mode]').forEach(e => { e.disabled = busy || !!recording; });
  $('record').textContent = recording ? '■   Stopp og transkriber' : busy ? 'Behandler …' : '◉   Start møte';
  $('record').classList.toggle('recording', !!recording);
  $('live').hidden = !recording;
  $('capture-state').hidden = !recording;
  $('cancel-recording').hidden = !recording;
  $('capture-state').textContent = recording ? (recording.dictation ? 'Diktering pågår · teksten kopieres ved stopp' : 'Opptak pågår · lyd lagres lokalt') : '';
}
async function refresh() {
  const state = await api.bootstrap(); meetings = state.meetings; ready = state.ready;
  if (!meetings.some(m => m.id === selected)) selected = meetings[0]?.id ?? '';
  input('api-key').placeholder = state.hasKey ? 'En nøkkel er lagret · lim inn for å erstatte' : 'Lim inn nøkkelen din';
  $('key-status').textContent = state.hasKey ? 'API-nøkkel lagret med Windows DPAPI.' : 'Ingen nøkkel lagret. Lokal transkripsjon kan brukes uten IDUN.';
  if (state.unreadable) message(`${state.unreadable} møtefil(er) kunne ikke leses. Filene er bevart i datamappen.`);
  showDownload(state.runtime); renderList(); renderDetail();
}
function renderList() {
  const visible = meetings.filter(m => searchMeeting(m, input('search').value)); $('meeting-count').textContent = String(visible.length);
  $('meetings').replaceChildren();
  for (const m of visible) {
    const button = document.createElement('button'); button.className = `meeting-row ${selected === m.id ? 'selected' : ''}`;
    button.innerHTML = `<b>${escape(m.title)}</b><small><span>${new Date(m.date).toLocaleDateString('nb-NO', { day: 'numeric', month: 'short' })}</span><span>${Math.round(m.duration / 60)} min &nbsp; ${m.state === 'completed' ? '✓' : '◷'}</span></small>`;
    button.onclick = () => { selected = m.id; renderList(); renderDetail(); }; $('meetings').append(button);
  }
  if (!visible.length) { const p = document.createElement('p'); p.className = 'small'; p.textContent = input('search').value ? 'Ingen treff i møtearkivet.' : 'Møtene dine vises her.'; $('meetings').append(p); }
}
function evidence(items: (Evidence | Action)[]) {
  return items.map((i, index) => `<div class="claim ${i.confidence === 'low' ? 'low' : ''}"><p>${'task' in i ? '○ &nbsp; ' + escape(i.task) : escape(i.text)}</p>${'task' in i ? `<small>${[i.owner, i.deadline, i.confidence === 'low' ? 'Usikkert' : ''].filter(Boolean).map(v => escape(v!)).join(' · ')}</small><button data-copy-action="${index}">Kopier gjøremål</button> ` : ''}<button class="evidence" data-evidence="${escape(i.evidence_segment_ids[0] ?? '')}">Vis kildeutsagn ↗</button></div>`).join('');
}
function showTab() {
  document.querySelectorAll<HTMLElement>('[data-view]').forEach(e => { e.hidden = e.dataset.view !== detailTab; });
  document.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach(e => { e.setAttribute('aria-selected', String(e.dataset.tab === detailTab)); });
}
function renderDetail() {
  const m = meetings.find(m => m.id === selected);
  if (!m) {
    $('detail').innerHTML = `<section class="empty"><div class="spark-mark">✱</div><h1>Plass til det som blir sagt.</h1><p>Start et møte for å bygge ditt lokale arkiv.<br>Spark tar vare på ordene, så du kan være til stede i samtalen.</p><button id="empty-start" class="primary">Start ditt første møte</button><p class="caption">Norsk tale · lokal transkripsjon · tydelige neste steg</p></section>`;
    bind('empty-start', () => toggleRecording(false)); return;
  }
  const a = m.analysis; const interrupted = ['recording', 'finalizing', 'transcribing'].includes(m.state) && recording?.id !== m.id;
  $('detail').innerHTML = `<header class="detail-header"><div class="row"><h1>${escape(m.title)}<span>✱</span></h1><button id="rename" title="Endre tittel">✎</button></div><time>${new Date(m.date).toLocaleDateString('nb-NO', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })}</time><div class="button-wrap"><button id="analyze" class="accent" ${busy || recording || !m.transcript.length ? 'disabled' : ''}>${a ? 'Analyser på nytt' : 'Oppsummer møte'}</button><button id="copy-summary" ${!a ? 'disabled' : ''}>Kopier oppsummering</button><button id="copy-actions" ${!a ? 'disabled' : ''}>Kopier gjøremål</button><button id="copy-all">Kopier alt</button><button id="export">Eksporter</button><button id="delete" ${busy || recording ? 'disabled' : ''}>Slett</button></div></header>
    ${busy ? `<div class="card processing"><div class="spinner"></div><div><b>${escape(operation)}</b><p class="small">Forløpt: <span id="operation-elapsed">00:00</span> · Du kan la Spark arbeide videre.</p></div></div>` : ''}
    ${interrupted && !busy ? '<div class="notice"><b>Et avbrutt opptak er bevart.</b><p>Gjenopprett avsluttede lydsegmenter og kjør lokal transkripsjon på nytt.</p><button id="recover">Gjenopprett / prøv CPU-transkripsjon igjen</button></div>' : ''}
    ${m.state === 'analyzing' && !busy ? '<div class="notice">Forrige analyse ble avbrutt. Transkripsjonen er bevart. Velg Oppsummer møte for å prøve igjen.</div>' : ''}
    ${a ? `<section class="card"><h2><span>≡</span> Oppsummering</h2><div class="summary-text">${escape(a.summary)}</div></section><section class="card"><h2><span>◌</span> Dette ble diskutert</h2>${evidence(a.key_points) || '<p class="small">Ingen punkter.</p>'}</section><section class="card"><h2><span>✓</span> Beslutninger</h2>${evidence(a.decisions) || '<p class="small">Ingen bekreftede beslutninger.</p>'}</section><section class="card"><h2><span>□</span> Gjøremål</h2>${evidence(a.action_items) || '<p class="small">Ingen bekreftede gjøremål.</p>'}</section><section class="card"><h2><span>?</span> Åpne spørsmål</h2>${evidence(a.open_questions) || '<p class="small">Ingen åpne spørsmål.</p>'}</section>` : !busy && !interrupted && m.transcript.length ? '<section class="card"><h2><span>✱</span> Transkripsjonen er klar.</h2><p>Les gjennom teksten nedenfor, eller oppsummer møtet med NTNU IDUN.</p><p class="small">Du får bekrefte før transkripsjonen sendes.</p></section>' : ''}
    <details id="transcript" ${!a ? 'open' : ''}><summary>Transkripsjon <span class="badge">${m.transcript.length} utsagn</span></summary><div class="card">${m.transcript.map(s => `<div class="transcript-row" id="segment-${escape(s.id)}"><span class="stamp">${time(s.start)}</span><button class="speaker" data-speaker="${escape(s.speaker ?? 'Ukjent')}">${escape(s.speaker ?? 'Ukjent')} ✎</button><p>${escape(s.text)}</p></div>`).join('') || '<p class="small">Venter på tale …</p>'}</div></details>`;
  bind('analyze', async () => { setBusy(true, 'Analyserer møte med IDUN …'); try { await api.analyze(m.id, input('analysis-mode').value === 'borealis'); } finally { setBusy(false); await refresh(); } });
  const tabs = document.createElement('div'); tabs.className = 'detail-tabs'; tabs.setAttribute('role', 'tablist'); tabs.setAttribute('aria-label', 'Møtevisning');
  tabs.innerHTML = '<button role="tab" data-tab="notes">Møtenotat</button><button role="tab" data-tab="todos">Gjøremål</button><button role="tab" data-tab="base">Kopier til basen</button>';
  $('detail').querySelector('.detail-header')!.after(tabs);
  // Match the three detail views in the Mac client while keeping source navigation available.
  for (const section of $('detail').querySelectorAll<HTMLElement>('section.card')) section.dataset.view = section.querySelector('h2')?.textContent?.includes('Gjøremål') ? 'todos' : 'notes';
  $('transcript').dataset.view = 'notes';
  if (!a?.action_items.length) { const empty = document.createElement('section'); empty.className = 'card'; empty.dataset.view = 'todos'; empty.textContent = 'Ingen gjøremål. Oppsummer møtet for å hente ut avtalte gjøremål.'; $('detail').append(empty); }
  const base = document.createElement('section'); base.className = 'card'; base.dataset.view = 'base';
  base.innerHTML = `<h2>Klar for basen</h2><div class="base-text">${escape(baseEntry(m))}</div><button id="copy-base" class="accent">Kopier hele teksten</button>`; $('detail').append(base);
  document.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach(b => b.onclick = () => { detailTab = b.dataset.tab!; showTab(); });
  bind('copy-base', async () => { await api.copy(m.id, 'base'); message('Møtenotatet er kopiert og klart for basen.'); });
  document.querySelectorAll<HTMLButtonElement>('[data-copy-action]').forEach(b => b.onclick = () => void task(async () => { await api.copyAction(m.id, Number(b.dataset.copyAction)); message('Gjøremålet er kopiert.'); }));
  showTab();
  bind('delete', async () => { await api.delete(m.id); await refresh(); });
  bind('rename', async () => { const title = await edit('Endre møtetittel', 'Tittel', m.title); if (title) { await api.rename(m.id, title); await refresh(); } });
  bind('export', async () => { await api.export(m.id); });
  for (const [id, kind] of [['copy-summary', 'summary'], ['copy-actions', 'actions'], ['copy-all', 'all']]) bind(id, async () => { await api.copy(m.id, kind); message('Kopiert til utklippstavlen.'); });
  if ($('recover')) bind('recover', async () => { if (!ready) { settings.showModal(); return; } setBusy(true, 'Gjenoppretter og transkriberer lokalt …'); try { await api.recover(m.id); } finally { setBusy(false); await refresh(); } });
  document.querySelectorAll<HTMLButtonElement>('[data-evidence]').forEach(b => b.onclick = () => { detailTab = 'notes'; showTab(); $<HTMLDetailsElement>('transcript').open = true; const target = document.getElementById(`segment-${b.dataset.evidence}`); target?.scrollIntoView({ behavior: 'smooth', block: 'center' }); target?.classList.add('highlight'); setTimeout(() => target?.classList.remove('highlight'), 4000); });
  document.querySelectorAll<HTMLButtonElement>('[data-speaker]').forEach(b => b.onclick = () => void task(async () => { const name = await edit('Endre talernavn', 'Navn', b.dataset.speaker!); if (name) { await api.speaker(m.id, b.dataset.speaker, name); await refresh(); } }));
}
async function edit(heading: string, label: string, value: string): Promise<string | null> {
  const dialog = $<HTMLDialogElement>('edit-dialog'); $('edit-heading').textContent = heading; $('edit-label').textContent = label; input('edit-value').value = value; dialog.returnValue = ''; dialog.showModal(); input('edit-value').select();
  return new Promise(resolve => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'save' ? input('edit-value').value.trim() : null), { once: true }));
}
function showDownload(p: DownloadProgress) {
  if (!startupChecked && !['checking'].includes(p.phase)) { startupChecked = true; if (p.phase !== 'ready' && !settings.open) settings.showModal(); }
  ready = p.phase === 'ready'; $('ready-label').textContent = ready ? '✓ NB-Whisper klar' : p.phase === 'checking' ? 'Kontrollerer …' : 'Klargjør Whisper';
  const active = ['checking', 'downloading', 'verifying', 'runtime-downloading', 'runtime-verifying'].includes(p.phase);
  $('download-label').textContent = p.phase === 'ready' ? '✓ Runtime og norsk talemodell er klare.' : p.phase === 'paused' ? 'Nedlastingen er satt på pause. Fortsett når du vil.' : p.phase === 'error' ? p.error ?? 'Nedlastingen feilet. Prøv igjen.' : p.phase.includes('verifying') ? 'Verifiserer SHA-256 før installasjon …' : p.phase.includes('downloading') ? `${p.phase.startsWith('runtime') ? 'Whisper-runtime' : 'Norsk talemodell'}: ${(p.received / 1048576).toFixed(1)} av ${(p.total / 1048576).toFixed(1)} MiB` : p.phase === 'checking' ? 'Kontrollerer lokale filer …' : 'Whisper må klargjøres før første transkripsjon.';
  const progress = $<HTMLProgressElement>('download-progress'); progress.max = p.total || 1; progress.value = p.received;
  progress.hidden = !active && p.phase !== 'paused';
  if (p.phase.includes('verifying') || p.phase === 'checking') progress.removeAttribute('value');
  $('setup-start').textContent = p.phase === 'paused' ? 'Fortsett nedlasting' : p.phase === 'error' ? 'Prøv igjen / reparer' : ready ? 'Reparer installasjon' : 'Last ned og klargjør';
  $<HTMLButtonElement>('setup-start').disabled = active;
  $<HTMLButtonElement>('setup-pause').disabled = !p.phase.includes('downloading');
  $<HTMLButtonElement>('setup-check').disabled = active;
}
async function cleanupCapture() { for (const stream of streams) for (const track of stream.getTracks()) track.stop(); streams = []; worklet?.disconnect(); worklet = undefined; await context?.close(); context = undefined; }
async function toggleRecording(dictation: boolean) {
  if (busy || stopping) return;
  if (recording) { await stopRecording(); return; }
  if (!ready) { settings.showModal(); return; }
  const mode = dictation ? 'microphone' : document.querySelector<HTMLInputElement>('input[name=mode]:checked')!.value;
  setBusy(true, 'Starter opptak …');
  try {
    await api.prepareCapture(mode);
    const mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: mode === 'system', noiseSuppression: true, channelCount: 1 }, video: false }); streams.push(mic);
    if (mode === 'system') {
      const system = await navigator.mediaDevices.getDisplayMedia({ video: { width: 1, height: 1, frameRate: 1 }, audio: true }); streams.push(system);
      // Chromium requires a video track to request loopback. Stop it immediately;
      // only audio tracks ever enter the WebAudio graph or disk IPC.
      system.getVideoTracks().forEach(t => t.stop());
      if (!system.getAudioTracks().length) throw new Error('Windows ga ingen systemlyd. Kontroller lydutgangen, eller velg bare mikrofon.');
    }
    context = new AudioContext({ sampleRate: 16000 });
    if (context.sampleRate !== 16000) throw new Error('Lydsystemet støtter ikke forventet samplingsfrekvens.');
    await context.audioWorklet.addModule('capture-worklet.js');
    worklet = new AudioWorkletNode(context, 'spark-capture');
    const m: Meeting = await api.start(dictation); recording = { id: m.id, dictation, started: Date.now() }; selected = m.id; captureFailed = false;
    chunkQueue = Promise.resolve();
    worklet.port.onmessage = event => {
      if (event.data.flushed) { flushResolve?.(); return; }
      if (!recording || !event.data.samples) return;
      const id = recording.id; const samples = event.data.samples as Float32Array;
      chunkQueue = chunkQueue.then(() => api.chunk(id, samples)).catch(e => { captureFailed = true; message(`Lagring av lyd feilet: ${e.message}. Stopper opptaket.`); if (!stopping) void task(stopRecording); });
    };
    for (const stream of streams) {
      context.createMediaStreamSource(new MediaStream(stream.getAudioTracks())).connect(worklet);
      for (const track of stream.getAudioTracks()) track.onended = () => { if (recording && !stopping) { message('Lydkilden ble koblet fra. Opptaket avsluttes og lagret lyd beholdes.'); void task(stopRecording); } };
    }
    const mute = context.createGain(); mute.gain.value = 0; worklet.connect(mute).connect(context.destination); await context.resume();
    $('live-text').textContent = 'Lytter. Første tekst kommer etter et avsluttet lydsegment …';
    await refresh();
  } catch (e) {
    await cleanupCapture(); if (recording) await api.abandonStart().catch(() => {}); recording = undefined;
    throw new Error(`Opptaket kunne ikke starte. ${(e as Error).message} Kontroller Windows Innstillinger → Personvern og sikkerhet → Mikrofon, og gi skrivebordsapper tilgang.`);
  } finally { setBusy(false); controls(); }
}
async function stopRecording() {
  if (!recording || stopping) return; stopping = true; const current = recording;
  try {
    if (worklet) await new Promise<void>(resolve => { let done = false; const complete = () => { if (!done) { done = true; resolve(); } }; flushResolve = complete; worklet!.port.postMessage('flush'); setTimeout(complete, 2000); });
    await cleanupCapture(); await chunkQueue; recording = undefined; setBusy(true, 'Transkriberer lokalt med NB-Whisper …');
    await api.finish(current.id, current.dictation);
    if (captureFailed) message('Noen lydsegmenter kunne ikke lagres. Transkripsjonen inneholder bare bevart lyd.');
    else if (current.dictation) message('Dikteringen er kopiert. Trykk Ctrl+V der teksten skal settes inn.');
  } finally { recording = undefined; stopping = false; setBusy(false); await refresh(); controls(); }
}
bind('record', () => toggleRecording(false)); bind('dictate', () => toggleRecording(true));
bind('cancel-recording', async () => {
  if (!recording || stopping || !await api.confirmCancel()) return;
  stopping = true;
  try { await cleanupCapture(); await chunkQueue; await api.cancelRecording(); recording = undefined; message('Opptaket er avbrutt og slettet.'); }
  finally { stopping = false; controls(); await refresh(); }
});
bind('delete-all', async () => { await api.deleteAll(); await refresh(); });
bind('settings-open', () => settings.showModal()); bind('settings-close', () => settings.close()); bind('settings-done', () => settings.close()); bind('status-close', () => { $('status').hidden = true; });
bind('setup-start', async () => { await api.setup(); }); bind('setup-pause', async () => { await api.pauseSetup(); }); bind('setup-cancel', async () => { await api.cancelSetup(); }); bind('setup-check', async () => { await api.checkSetup(); }); bind('setup-remove', async () => { await api.removeModel(); });
bind('key-page', async () => { await api.keyPage(); });
bind('key-save', async () => { await api.saveKey(input('api-key').value); input('api-key').value = ''; await refresh(); message('API-nøkkelen er lagret sikkert.'); });
bind('key-remove', async () => { await api.removeKey(); input('api-key').value = ''; await refresh(); message('API-nøkkelen er fjernet.'); });
async function testIDUN() { $('key-status').textContent = 'Tester IDUN …'; try { const reply = await api.testKey(); $('key-status').textContent = reply; message(reply); } catch (e) { $('key-status').textContent = (e as Error).message; throw e; } }
bind('key-test', testIDUN); bind('test-idun', testIDUN);
bind('open-folder', async () => { await api.openFolder(); }); bind('diagnostics', async () => { $('diagnostic-output').textContent = JSON.stringify(await api.diagnostics(), null, 2); $('diagnostic-output').hidden = false; });
input('detect-toggle').addEventListener('change', () => void api.detection(input('detect-toggle').checked));
bind('detected-dismiss', () => { $('detected').hidden = true; }); bind('detected-start', async () => { $('detected').hidden = true; await toggleRecording(false); });
input('search').addEventListener('input', renderList);
document.querySelectorAll<HTMLInputElement>('input[name=mode]').forEach(radio => radio.addEventListener('change', () => { $('system-hint').hidden = document.querySelector<HTMLInputElement>('input[name=mode]:checked')!.value !== 'system'; }));
bind('import-text', async () => { const id = await api.importText(); if (id) selected = id; await refresh(); });
bind('import-audio', async () => {
  if (!ready) { settings.showModal(); return; } const file = await api.chooseAudio(); if (!file) return;
  setBusy(true, 'Dekoder og transkriberer lyd lokalt …');
  try {
    const decoder = new AudioContext({ sampleRate: 16000 }); let decoded: AudioBuffer;
    try { decoded = await decoder.decodeAudioData(new Uint8Array(file.data).buffer); } catch { throw new Error('Lydformatet kunne ikke dekodes. Prøv WAV, MP3, FLAC eller M4A.'); } finally { await decoder.close(); }
    if (decoded.duration > 7200) throw new Error('Lydfilen er lengre enn to timer. Del filen før import.');
    const offline = new OfflineAudioContext(1, Math.ceil(decoded.duration * 16000), 16000); const source = offline.createBufferSource(); source.buffer = decoded; source.connect(offline.destination); source.start(); const mono = await offline.startRendering();
    const m = await api.importPCM(file.name, mono.getChannelData(0)); selected = m.id;
  } finally { setBusy(false); await refresh(); }
});
api.on('download', showDownload); api.on('status', message); api.on('changed', () => void task(refresh));
api.on('live', (m: Meeting) => { if (recording?.id === m.id) { $('live-text').textContent = m.transcript.slice(-5).map((s: Segment) => s.text).join(' '); const i = meetings.findIndex(old => old.id === m.id); if (i >= 0) meetings[i] = m; renderDetail(); } });
api.on('shortcut', (kind: string) => { if (kind === 'cancel') { $('cancel-recording').click(); return; } if (kind === 'stop') { void task(stopRecording); return; } if (settings.open) { message('Lukk innstillingene før du starter opptak.'); return; } void task(() => toggleRecording(kind === 'dictation')); });
api.on('suspend', () => { if (recording) void task(stopRecording); });
api.on('detected', (name: string) => { $('detected-label').textContent = `${name} er oppdaget`; $('detected').hidden = false; });
setInterval(() => { if (recording) { $('elapsed').textContent = time((Date.now() - recording.started) / 1000); document.title = `● Opptak ${$('elapsed').textContent} — Spark NTNU`; } else document.title = 'Spark NTNU'; const elapsed = $('operation-elapsed'); if (elapsed) elapsed.textContent = time((Date.now() - operationStarted) / 1000); }, 500);
void task(refresh);

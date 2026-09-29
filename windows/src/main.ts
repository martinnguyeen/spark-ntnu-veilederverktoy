import { app, BrowserWindow, ipcMain, dialog, safeStorage, clipboard, shell, session, desktopCapturer, globalShortcut, powerSaveBlocker, powerMonitor } from 'electron';
import { join, basename, extname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { mkdir, readFile, rm, statfs, stat } from 'node:fs/promises';
import { release, arch, cpus, totalmem } from 'node:os';
import { Repository, atomicWrite } from './storage';
import { Runtime } from './runtime';
import { AudioService } from './audio';
import { markdown, validateMeeting, baseEntry } from './domain';
import { RecordingBar } from './recording-bar';
import { enforceRetention } from './retention';
import { analyze, testConnection } from './idun';
import { readTextDocument, textSegments } from './import';

app.setName('Spark NTNU');
app.setAppUserModelId('no.spark.ntnu.windows');
// Test data isolation is only available in an unpackaged developer build.
const root = !app.isPackaged && process.env.SPARK_TEST_DATA ? process.env.SPARK_TEST_DATA : join(process.env.LOCALAPPDATA ?? app.getPath('appData'), 'SparkNTNU');
app.setPath('userData', root);
const page = pathToFileURL(join(__dirname, 'index.html')).href;
let win: BrowserWindow; let captureUntil = 0; let captureMode = ''; let blocker: number | undefined; let analyzing = false;
let recordingBar: RecordingBar;
const repo = new Repository(join(root, 'Meetings'));
const emit = (channel: string, data: unknown) => { if (win && !win.isDestroyed()) win.webContents.send(`spark:${channel}`, data); };
const runtime = new Runtime(root, p => emit('download', p));
const audio = new AudioService(repo, runtime, emit);
const keyPath = join(root, 'idun-key.dpapi');
function assertIdle() { if (audio.active || audio.busy || analyzing) throw new Error('Vent til opptaket eller oppgaven er ferdig.'); }
async function key() { if (process.platform !== 'win32' || !safeStorage.isEncryptionAvailable()) throw new Error('Windows-beskyttet nøkkellagring er ikke tilgjengelig.'); try { return safeStorage.decryptString(await readFile(keyPath)); } catch { throw new Error('Legg inn IDUN API-nøkkelen i innstillingene.'); } }
function releaseBlocker() { recordingBar?.stop(); if (blocker !== undefined && powerSaveBlocker.isStarted(blocker)) powerSaveBlocker.stop(blocker); blocker = undefined; }
function handle(name: string, callback: (...args: any[]) => unknown) {
  ipcMain.handle(`spark:${name}`, async (event, ...args) => {
    if (event.sender !== win.webContents || event.senderFrame !== win.webContents.mainFrame || event.senderFrame.url !== page) throw new Error('Ugyldig IPC-avsender.');
    return callback(...args);
  });
}
async function confirmed(title: string, message: string, button: string) { return (await dialog.showMessageBox(win, { type: 'question', title, message, buttons: ['Avbryt', button], defaultId: 0, cancelId: 0, noLink: true })).response === 1; }

async function initialize() {
  await mkdir(root, { recursive: true });
  await enforceRetention(repo);
  win = new BrowserWindow({ width: 1240, height: 850, minWidth: 980, minHeight: 680, title: 'Spark NTNU', icon: join(__dirname, 'spark.ico'), backgroundColor: '#fafaf8', autoHideMenuBar: true, show: false, webPreferences: { preload: join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false, webSecurity: true, spellcheck: false, backgroundThrottling: false } });
  recordingBar = new RecordingBar(win, __dirname, action => emit('shortcut', action));
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', event => event.preventDefault());
  win.webContents.on('will-attach-webview', event => event.preventDefault());
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback, details) => {
    callback(contents === win.webContents && contents.getURL() === page && Date.now() < captureUntil && permission === 'media' && 'mediaTypes' in details && (details.mediaTypes ?? []).every((type: string) => type === 'audio'));
  });
  session.defaultSession.setPermissionCheckHandler((contents, permission) => contents === win.webContents && contents?.getURL() === page && Date.now() < captureUntil && (permission === 'media' || permission === 'display-capture'));
  session.defaultSession.setDisplayMediaRequestHandler(async (request, callback) => {
    if (request.frame !== win.webContents.mainFrame || Date.now() >= captureUntil || captureMode !== 'system') { callback({}); return; }
    try {
      const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } });
      if (!sources[0]) { callback({}); return; }
      callback({ video: sources[0], audio: 'loopback' });
    } catch { callback({}); }
  });
  handle('bootstrap', async () => ({ ...await repo.list(), runtime: runtime.progress, ready: runtime.ready, hasKey: await stat(keyPath).then(() => true).catch(() => false), folder: root }));
  handle('setup', () => { assertIdle(); void runtime.start(); });
  handle('pauseSetup', () => runtime.pause());
  handle('cancelSetup', () => runtime.cancel());
  handle('checkSetup', async () => { assertIdle(); if (runtime.task) throw new Error('Vent til nedlastingen er ferdig.'); const ready = await runtime.check(); runtime.update({ phase: ready ? 'ready' : 'missing', received: 0, total: 0 }); return ready; });
  handle('removeModel', async () => { assertIdle(); if (await confirmed('Fjern lokal modell?', 'Talemodellen må lastes ned igjen før transkripsjon. Møter og API-nøkkel beholdes.', 'Fjern modell')) await runtime.removeModel(); });
  handle('saveKey', async (value: unknown) => { if (typeof value !== 'string' || value.trim().length < 8 || value.length > 4096 || /[\r\n]/.test(value)) throw new Error('Ugyldig API-nøkkel.'); if (process.platform !== 'win32' || !safeStorage.isEncryptionAvailable()) throw new Error('Sikker Windows-lagring er ikke tilgjengelig.'); await atomicWrite(keyPath, safeStorage.encryptString(value.trim())); });
  handle('removeKey', () => rm(keyPath, { force: true }));
  handle('testKey', async () => testConnection(await key()));
  handle('keyPage', () => shell.openExternal('https://ai.hpc.ntnu.no/request-api-key'));
  handle('openFolder', () => shell.openPath(root));
  handle('diagnostics', async () => { const disk = await statfs(root); return { os: release(), architecture: arch(), cpu: cpus()[0]?.model, memoryGB: Math.round(totalmem() / 1024 ** 3), freeGB: Math.floor(disk.bavail * disk.bsize / 1024 ** 3), app: app.getVersion(), electron: process.versions.electron, ready: runtime.ready, audio: 'CPU · norsk · 16 kHz mono', folder: root }; });
  handle('prepareCapture', async (mode: unknown) => { assertIdle(); if (!runtime.ready) throw new Error('Åpne innstillingene og last ned Whisper først.'); if (mode !== 'microphone' && mode !== 'system') throw new Error('Ugyldig lydkilde.'); captureMode = mode; captureUntil = Date.now() + 60000; });
  handle('start', async (dictation: unknown) => { assertIdle(); if (Date.now() >= captureUntil) throw new Error('Velg Start møte på nytt.'); const m = await audio.start(dictation === true); captureUntil = 0; blocker = powerSaveBlocker.start('prevent-app-suspension'); recordingBar.start(); return m; });
  handle('chunk', (id: string, samples: Float32Array) => audio.chunk(id, samples));
  handle('abandonStart', async () => { try { await audio.abandonStart(); } finally { releaseBlocker(); } });
  handle('confirmCancel', () => confirmed('Avbryt opptaket?', 'Lyd og foreløpig tekst fra det pågående opptaket slettes.', 'Avbryt og slett'));
  handle('cancelRecording', async () => { try { await audio.cancel(); } finally { releaseBlocker(); } });
  handle('finish', async (id: string, dictation: boolean) => { recordingBar.stop(); try { const m = await audio.finish(id); if (dictation === true) { await clipboard.writeText(m.transcript.map(s => s.text).join(' ')); emit('status', 'Dikteringen er kopiert. Trykk Ctrl+V der teksten skal settes inn.'); } return m; } finally { releaseBlocker(); } });
  handle('recover', async (id: string) => { assertIdle(); return audio.finish(id); });
  handle('delete', async (id: string) => { assertIdle(); const m = await repo.load(id); if (await confirmed('Slett møte?', `Slett «${m.title}» og tilhørende lyd permanent fra denne PC-en?`, 'Slett')) await repo.delete(id); });
  handle('deleteAll', async () => { assertIdle(); const { meetings } = await repo.list(); if (meetings.length && await confirmed('Slett alle møter?', `Slett ${meetings.length} møter med lyd permanent fra denne PC-en? Modell og API-nøkkel beholdes.`, 'Slett alle møter')) for (const m of meetings) await repo.delete(m.id); });
  handle('rename', async (id: string, title: unknown) => { assertIdle(); if (typeof title !== 'string' || !title.trim() || title.length > 500) throw new Error('Skriv en møtetittel på 1–500 tegn.'); const m = await repo.load(id); m.title = title.trim(); await repo.save(m); });
  handle('speaker', async (id: string, oldName: unknown, newName: unknown) => { assertIdle(); if (typeof oldName !== 'string' || typeof newName !== 'string' || !newName.trim() || newName.length > 100) throw new Error('Ugyldig navn.'); const m = await repo.load(id); for (const s of m.transcript) if ((s.speaker ?? 'Ukjent') === oldName) s.speaker = newName.trim(); await repo.save(m); });
  handle('export', async (id: string) => { const m = await repo.load(id); const result = await dialog.showSaveDialog(win, { defaultPath: `${m.title.replace(/[<>:"/\\|?*]/g, '_')}.md`, filters: [{ name: 'Markdown', extensions: ['md'] }, { name: 'Møte JSON (Mac/Windows)', extensions: ['json'] }] }); if (result.filePath) await atomicWrite(result.filePath, extname(result.filePath).toLowerCase() === '.json' ? JSON.stringify(m, null, 2) : markdown(m)); });
  handle('copy', async (id: string, kind: string) => { const m = await repo.load(id); await clipboard.writeText(kind === 'base' ? baseEntry(m) : kind === 'summary' ? m.analysis?.summary ?? '' : kind === 'actions' ? m.analysis?.action_items.filter(i => i.confidence !== 'low').map(i => `• ${i.task}`).join('\n') ?? '' : markdown(m)); });
  handle('copyAction', async (id: string, index: unknown) => { const m = await repo.load(id); if (typeof index !== 'number' || !Number.isInteger(index) || index < 0 || !m.analysis?.action_items[index]) throw new Error('Ugyldig gjøremål.'); await clipboard.writeText(m.analysis.action_items[index].task); });
  handle('importText', async () => { assertIdle(); const result = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Tekst eller møte', extensions: ['txt', 'md', 'rtf', 'json'] }] }); if (result.canceled) return; const path = result.filePaths[0]; if ((await stat(path)).size > 10 * 1024 * 1024) throw new Error('Tekstfilen er for stor (maks 10 MB).'); const text = await readTextDocument(path); if (extname(path).toLowerCase() === '.json') { const m = validateMeeting(JSON.parse(text)); const copy = await repo.create(m.title); await repo.save({ ...m, id: copy.id }); return copy.id; } if (!text.trim()) throw new Error('Tekstfilen er tom.'); const m = await repo.create(basename(path, extname(path))); m.state = 'transcriptReady'; m.transcript = textSegments(text); await repo.save(m); return m.id; });
  handle('chooseAudio', async () => { assertIdle(); if (!runtime.ready) throw new Error('Last ned Whisper i innstillingene først.'); const result = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Lyd (dekodes lokalt)', extensions: ['wav', 'mp3', 'm4a', 'flac', 'ogg', 'webm'] }] }); if (result.canceled) return; const path = result.filePaths[0]; if ((await stat(path)).size > 250 * 1024 * 1024) throw new Error('Lydimport er begrenset til 250 MB per fil.'); return { name: basename(path, extname(path)), data: new Uint8Array(await readFile(path)) }; });
  handle('importPCM', async (title: unknown, pcm: Float32Array) => { assertIdle(); if (typeof title !== 'string') throw new Error('Ugyldig filnavn.'); return audio.importPCM(title, pcm); });
  handle('analyze', async (id: string, borealis: boolean) => {
    assertIdle(); const m = await repo.load(id); if (!m.transcript.length) throw new Error('Møtet har ingen transkripsjon.');
    analyzing = true;
    try {
      if (!await confirmed('Send transkripsjon til NTNU IDUN?', 'Transkripsjon og møtemetadata sendes direkte fra denne PC-en til NTNU IDUN for analyse. Rå lyd blir på PC-en. Du må være tilkoblet eduroam eller NTNU VPN.', 'Send og analyser')) return;
      m.state = 'analyzing'; await repo.save(m); emit('changed', null);
      m.analysis = await analyze(m, await key(), borealis === true, true, __dirname, text => emit('status', text)); m.state = 'completed'; await repo.save(m);
    } catch (e) { m.state = 'completedWithoutAnalysis'; await repo.save(m); throw e; }
    finally { analyzing = false; emit('changed', null); }
  });
  win.on('close', event => {
    if (audio.active || audio.busy || analyzing) { event.preventDefault(); win.show(); emit('status', 'Fullfør opptaket eller vent til oppgaven er ferdig før du lukker Spark.'); }
  });
  powerMonitor.on('suspend', () => { if (audio.active) emit('suspend', null); });
  await win.loadFile(join(__dirname, 'index.html')); win.show();
  for (const [accelerator, kind] of [['CommandOrControl+Shift+Space', 'meeting'], ['CommandOrControl+Shift+D', 'dictation']]) {
    if (!globalShortcut.register(accelerator, () => { win.show(); emit('shortcut', kind); })) emit('status', `Snarveien ${accelerator} er opptatt av et annet program. Bruk knappene i Spark.`);
  }
  runtime.update({ phase: 'checking', received: 0, total: 0 });
  void runtime.check().then(ready => runtime.update({ phase: ready ? 'ready' : 'missing', received: 0, total: 0 })).catch(() => runtime.update({ phase: 'missing', received: 0, total: 0 }));
  // Opt-in detection examines window titles only, never content or screenshots.
  let detection = false; let seen = ''; let scanning = false;
  handle('detection', (enabled: unknown) => { detection = enabled === true; seen = ''; });
  const timer = setInterval(async () => {
    if (!detection || scanning || audio.active || audio.busy || analyzing) return;
    scanning = true;
    try { const windows = await desktopCapturer.getSources({ types: ['window'], thumbnailSize: { width: 0, height: 0 } }); const match = windows.find(w => /Microsoft Teams|Zoom Meeting|Meet -|Google Meet/i.test(w.name)); if (!match) seen = ''; else if (match.id !== seen) { seen = match.id; emit('detected', /zoom/i.test(match.name) ? 'Zoom' : /teams/i.test(match.name) ? 'Teams' : 'Google Meet'); } } catch { /* Optional detection must not affect capture. */ } finally { scanning = false; }
  }, 15000);
  timer.unref();
}
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { win?.show(); win?.focus(); });
  app.whenReady().then(initialize).catch(() => { dialog.showErrorBox('Spark kunne ikke starte', 'Kontroller at appen har tilgang til den lokale datamappen.'); app.quit(); });
}
app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => { globalShortcut.unregisterAll(); releaseBlocker(); });

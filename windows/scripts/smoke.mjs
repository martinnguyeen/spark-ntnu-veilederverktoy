import { _electron as electron } from 'playwright';
import { mkdtemp, mkdir, writeFile, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';
const root = await mkdtemp(join(tmpdir(), 'spark-ui-'));
const id = 'D1C4D4D1-8780-4812-94D0-B46CFA709C2C';
const meeting = { id, title: 'Veiledning – litteraturgjennomgang', date: '2026-09-24T10:00:00Z', duration: 2754, state: 'completed', transcript: [{ id: 's1', start: 8, end: 18, speaker: 'Veileder', text: 'Vi bestemmer at du sender det reviderte utkastet før fredag.' }, { id: 's2', start: 42, end: 55, speaker: 'Martin', text: 'Jeg strammer inn problemstillingen og legger ved søkeloggen.' }], analysis: { schema_version: '1.0', summary: 'Problemstillingen skal avgrenses tydeligere, og søkeloggen skal følge neste utkast. Gruppen ble enige om levering før fredag.', key_points: [{ text: 'Søkeloggen må gjøre utvalget av litteratur etterprøvbart.', confidence: 'high', evidence_segment_ids: ['s2'] }], decisions: [{ text: 'Revidert utkast sendes før fredag.', confidence: 'high', evidence_segment_ids: ['s1'] }], action_items: [{ task: 'Send revidert utkast', owner: 'Martin', deadline: 'Fredag', confidence: 'high', evidence_segment_ids: ['s1', 's2'] }], open_questions: [{ text: 'Hvordan skal budsjettet avklares?', evidence_segment_ids: ['s2'] }] } };
await mkdir(join(root, 'Meetings', id), { recursive: true }); await writeFile(join(root, 'Meetings', id, 'meeting.json'), JSON.stringify(meeting));
await mkdir('test-results', { recursive: true });
const environment = { ...process.env, SPARK_TEST_DATA: root }; delete environment.ELECTRON_RUN_AS_NODE;
const instance = await electron.launch({ args: ['.'], env: environment });
try {
  const page = await instance.firstWindow(); const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.locator('#settings[open]').waitFor(); await page.locator('#download-label').filter({ hasText: 'klargjøres' }).waitFor();
  await page.screenshot({ path: 'test-results/onboarding.png' });
  await page.locator('#api-key').fill('fake-key-for-dpapi-test'); await page.locator('#key-save').click(); await page.locator('#key-status').filter({ hasText: 'lagret med Windows' }).waitFor();
  assert.equal((await readFile(join(root, 'idun-key.dpapi'))).includes(Buffer.from('fake-key-for-dpapi-test')), false);
  await page.locator('#key-remove').click(); await page.locator('#key-status').filter({ hasText: 'Ingen nøkkel' }).waitFor();
  await page.locator('#settings-done').click();
  await page.locator('#status-close').click(); await page.screenshot({ path: 'test-results/meeting.png' });
  assert.equal(await page.evaluate(() => typeof window.require), 'undefined');
  assert.equal(await page.evaluate(() => typeof window.process), 'undefined');
  await page.locator('[data-evidence]').first().click(); assert.equal(await page.locator('#transcript').getAttribute('open') !== null, true);
  await page.locator('#search').fill('finnesikke'); assert.equal(await page.locator('.meeting-row').count(), 0); await page.locator('#search').fill('fredag'); assert.equal(await page.locator('.meeting-row').count(), 1);
  await page.locator('#rename').click(); await page.locator('#edit-value').fill('Oppdatert veiledning'); await page.locator('#edit-save').click(); await page.locator('h1').filter({ hasText: 'Oppdatert veiledning' }).waitFor();
  // The automation host's Windows clipboard also reads empty from PowerShell.
  // Verify the IPC payload here; real desktop paste remains a manual acceptance gate.
  await instance.evaluate(({ clipboard }) => { globalThis.sparkClipboardTest = ''; clipboard.writeText = async text => { globalThis.sparkClipboardTest = text; }; });
  await page.locator('#copy-all').click(); await page.locator('#status-text').filter({ hasText: 'Kopiert til utklippstavlen' }).waitFor();
  const copied = await instance.evaluate(() => globalThis.sparkClipboardTest);
  assert.match(copied, /## Gjøremål/);
  await page.locator('[data-tab="base"]').click(); await page.locator('#copy-base').click();
  await page.locator('#status-text').filter({ hasText: 'klart for basen' }).waitFor();
  const baseText = await instance.evaluate(() => globalThis.sparkClipboardTest); assert.match(baseText, /To-Do/); assert.doesNotMatch(baseText, /## Transkripsjon/);
  await page.screenshot({ path: 'test-results/base.png', animations: 'disabled' });
  await page.locator('[data-tab="todos"]').click(); await page.locator('[data-copy-action]').click();
  await page.locator('#status-text').filter({ hasText: 'Gjøremålet er kopiert' }).waitFor(); assert.equal(await instance.evaluate(() => globalThis.sparkClipboardTest), 'Send revidert utkast');
  await page.locator('[data-tab="todos"]').press('Tab');
  await page.locator('[data-tab="notes"]').click();
  await instance.evaluate(({ dialog }) => { dialog.showMessageBox = async () => ({ response: 0, checkboxChecked: false }); });
  await page.locator('#analyze').click(); await page.locator('#analyze:enabled').waitFor();
  assert.equal(JSON.parse(await readFile(join(root, 'Meetings', id, 'meeting.json'), 'utf8')).state, 'completed');
  const exportPath = join(root, 'export.json'); await instance.evaluate(({ dialog }, path) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: path }); }, exportPath);
  await page.locator('#export').click(); await page.waitForTimeout(200); assert.equal(JSON.parse(await readFile(exportPath, 'utf8')).title, 'Oppdatert veiledning');
  await instance.evaluate(({ dialog }, path) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [path] }); }, exportPath);
  await page.locator('#import-text').click(); await page.waitForTimeout(300); assert.equal((await readdir(join(root, 'Meetings'))).length, 2);
  assert.deepEqual(errors, []); console.log('UI PASS: onboarding, DPAPI, library/search, evidence, rename, Mac detail tabs, base/action copy payload (stubbed), consent cancellation, JSON export/import, isolated renderer.');
} finally { await instance.close(); }

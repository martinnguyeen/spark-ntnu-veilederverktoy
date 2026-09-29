import { _electron as electron } from 'playwright';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
if (!process.env.SPARK_TEST_DATA) throw new Error('Set SPARK_TEST_DATA to the isolated provisioned acceptance folder.');
const env = { ...process.env }; delete env.ELECTRON_RUN_AS_NODE;
const instance = await electron.launch({ args: ['.', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${resolve('tests/fixtures/norwegian-synthetic.wav')}`], env });
try {
  const page = await instance.firstWindow(); const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.locator('#ready-label').filter({ hasText: 'NB-Whisper klar' }).waitFor({ timeout: 30000 });
  if (await page.locator('#settings').evaluate(d => d.open)) await page.locator('#settings-close').click();
  await page.locator('#record').click();
  await page.locator('#capture-state').filter({ hasText: 'Opptak pågår' }).waitFor({ timeout: 15000 });
  await page.locator('#live-text').filter({ hasText: /transkripsjon|fredag|utkast/ }).waitFor({ timeout: 60000 });
  await mkdir('test-results', { recursive: true }); await page.screenshot({ path: 'test-results/recording.png', animations: 'disabled' });
  await instance.evaluate(({ BrowserWindow }) => { BrowserWindow.getAllWindows().find(w => w.webContents.getURL().endsWith('/index.html')).minimize(); });
  const bar = instance.windows().find(w => w.url().endsWith('/bar.html')); assert.ok(bar);
  await bar.waitForFunction(() => document.visibilityState === 'visible');
  await bar.screenshot({ path: 'test-results/recording-bar.png' });
  assert.equal(await bar.evaluate(() => typeof window.spark), 'undefined');
  await bar.locator('[data-action="stop"]').click(); await page.locator('#record:enabled').filter({ hasText: 'Start møte' }).waitFor({ timeout: 120000 });
  const state = await page.evaluate(() => window.spark.bootstrap());
  const m = state.meetings[0]; assert.equal(m.state, 'transcriptReady'); assert.match(m.transcript.map(s => s.text).join(' '), /fredag|utkast/); assert.ok(m.duration >= 15);
  assert.deepEqual(errors, []); console.log(`Capture PASS: fake Norwegian microphone → 16 kHz WAV → live Whisper → minimize → floating bar stop → final transcript (${m.duration.toFixed(1)}s). No physical microphone used.`);
} finally { await instance.close(); }

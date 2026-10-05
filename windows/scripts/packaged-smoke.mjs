import { _electron as electron } from 'playwright';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
if (!process.argv[2]) throw new Error('Pass the built Spark NTNU.exe path. Uses an isolated LOCALAPPDATA directory.');
const localAppData = await mkdtemp(resolve(tmpdir(), 'spark-packaged-'));
const env = { ...process.env, LOCALAPPDATA: localAppData }; delete env.ELECTRON_RUN_AS_NODE;
const app = await electron.launch({ executablePath: resolve(process.argv[2]), args: [], env });
const processHandle = app.process();
try {
  // The hidden recording panel can be reported before the main window.
  let page;
  for (let attempt = 0; attempt < 100; attempt++) {
    page = app.windows().find(window => window.url().endsWith('/index.html'));
    if (page) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.ok(page, `Main window missing: ${app.windows().map(window => window.url()).join(', ')}`);
  await page.locator('.brand').waitFor();
  assert.equal(await app.evaluate(({ app }) => app.isPackaged), true);
  console.log('Packaged launch PASS:', await app.evaluate(({ app }) => ({ name: app.getName(), data: app.getPath('userData') })));
  const closed = app.waitForEvent('close', { timeout: 10000 });
  await app.evaluate(({ BrowserWindow }) => { for (const window of BrowserWindow.getAllWindows()) if (!window.isDestroyed()) window.close(); });
  await closed;
  console.log('Packaged window shutdown PASS');
} finally { if (processHandle.exitCode == null) { await app.close().catch(() => {}); if (processHandle.exitCode == null) processHandle.kill(); } }

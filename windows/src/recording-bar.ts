import { app, BrowserWindow, ipcMain, screen } from 'electron';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
export class RecordingBar {
  private window: BrowserWindow;
  private started = 0;
  private quitting = false;
  constructor(private main: BrowserWindow, directory: string, onControl: (action: string) => void) {
    const page = pathToFileURL(join(directory, 'bar.html')).href;
    const area = screen.getPrimaryDisplay().workArea;
    this.window = new BrowserWindow({ title: 'Spark – opptak', width: 460, height: 86, x: area.x + Math.round((area.width - 460) / 2), y: area.y + area.height - 105, frame: false, resizable: false, minimizable: false, maximizable: false, alwaysOnTop: true, skipTaskbar: true, show: false, icon: join(directory, 'spark.ico'), backgroundColor: '#fafaf8', webPreferences: { preload: join(directory, 'bar-preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false, backgroundThrottling: false } });
    app.on('before-quit', () => { this.quitting = true; });
    this.window.on('close', event => { if (!this.quitting && !this.main.isDestroyed()) { event.preventDefault(); this.window.hide(); } });
    main.on('closed', () => { this.quitting = true; if (!this.window.isDestroyed()) this.window.destroy(); });
    this.window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    this.window.webContents.on('will-navigate', e => e.preventDefault());
    ipcMain.on('spark:bar-control', (event, action: unknown) => {
      if (this.window.isDestroyed() || event.sender !== this.window.webContents || event.senderFrame !== this.window.webContents.mainFrame || event.senderFrame?.url !== page || !['stop', 'cancel', 'open'].includes(action as string)) return;
      this.main.show(); this.main.focus();
      if (this.started && action !== 'open') onControl(action as string);
    });
    void this.window.loadFile(join(directory, 'bar.html'));
    const refresh = () => setTimeout(() => this.refresh(), 0);
    main.on('blur', refresh); main.on('focus', refresh); main.on('minimize', refresh); main.on('restore', refresh);
  }
  start() { this.started = Date.now(); this.refresh(); }
  stop() { this.started = 0; this.refresh(); }
  private refresh() {
    if (this.window.isDestroyed()) return;
    if (this.main.isDestroyed()) { this.window.hide(); return; }
    if (this.started && !this.main.isFocused()) { this.window.webContents.send('spark:bar-state', this.started); this.window.showInactive(); }
    else this.window.hide();
  }
}

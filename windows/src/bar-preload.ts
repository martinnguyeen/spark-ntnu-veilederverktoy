import { contextBridge, ipcRenderer } from 'electron';
contextBridge.exposeInMainWorld('recordingBar', {
  control: (action: string) => { if (['stop', 'cancel', 'open'].includes(action)) ipcRenderer.send('spark:bar-control', action); },
  onState: (callback: (started: number) => void) => ipcRenderer.on('spark:bar-state', (_event, started) => callback(started))
});

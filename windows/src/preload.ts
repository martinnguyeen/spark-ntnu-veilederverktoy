import { contextBridge, ipcRenderer } from 'electron';
const operations = ['bootstrap', 'setup', 'pauseSetup', 'cancelSetup', 'checkSetup', 'removeModel', 'saveKey', 'removeKey', 'testKey', 'keyPage', 'openFolder', 'diagnostics', 'prepareCapture', 'start', 'chunk', 'abandonStart', 'finish', 'recover', 'delete', 'rename', 'speaker', 'export', 'copy', 'importText', 'chooseAudio', 'importPCM', 'analyze', 'detection'] as const;
const api: Record<string, unknown> = {};
for (const name of ['confirmCancel', 'cancelRecording', 'deleteAll', 'copyAction']) api[name] = (...args: unknown[]) => ipcRenderer.invoke(`spark:${name}`, ...args);
for (const name of operations) api[name] = (...args: unknown[]) => ipcRenderer.invoke(`spark:${name}`, ...args);
api.on = (channel: string, callback: (data: unknown) => void) => {
  if (!['download', 'status', 'changed', 'live', 'shortcut', 'suspend', 'detected'].includes(channel)) throw new Error('Ugyldig kanal.');
  const listener = (_event: unknown, value: unknown) => callback(value); ipcRenderer.on(`spark:${channel}`, listener);
  return () => ipcRenderer.removeListener(`spark:${channel}`, listener);
};
contextBridge.exposeInMainWorld('spark', api);

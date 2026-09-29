import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { run } from './process';
import { Segment } from './domain';
export function textSegments(text: string): Segment[] {
  const lines = text.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  if (!lines.length) throw new Error('Tekstfilen er tom.');
  return lines.map((line, i) => {
    const speaker = /^(Speaker [^:]+):\s*(.+)$/.exec(line);
    return { id: `s${i + 1}`, start: 0, end: 0, speaker: speaker?.[1] ?? null, text: speaker?.[2] ?? line };
  });
}
export async function readTextDocument(path: string) {
  const bytes = await readFile(path);
  if (bytes.subarray(0, 5).toString() === '{\\rtf') {
    // Fixed code only. The chosen path is JSON on stdin, never executable command text.
    const code = `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); Add-Type -AssemblyName System.Windows.Forms; $path = [Console]::In.ReadToEnd() | ConvertFrom-Json; $box = New-Object System.Windows.Forms.RichTextBox; try { $box.LoadFile($path); [Console]::Write($box.Text) } finally { $box.Dispose() }`;
    return run(join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', Buffer.from(code, 'utf16le').toString('base64')], 30000, JSON.stringify(path));
  }
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
  catch { return new TextDecoder('windows-1252').decode(bytes); }
}

import { spawn } from 'node:child_process';
export function run(executable: string, args: string[], timeout = 600000, input?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, shell: false }); let output = ''; let failed = false;
    child.stdin.on('error', () => {}); child.stdin.end(input);
    const timer = setTimeout(() => { failed = true; child.kill(); reject(new Error('Operasjonen tok for lang tid. Prøv igjen.')); }, timeout);
    child.stdout.on('data', b => { if (failed) return; if (output.length + b.length > 16_000_000) { failed = true; clearTimeout(timer); child.kill(); reject(new Error('Prosessen returnerte for mye tekst. Del filen og prøv igjen.')); } else output += b.toString(); });
    // Runtime stderr can contain transcript text; never forward it to diagnostic logs.
    child.stderr.resume();
    child.once('error', () => { clearTimeout(timer); reject(new Error('Kunne ikke starte den lokale prosessen. Bruk Reparer i innstillingene.')); });
    child.once('exit', code => { clearTimeout(timer); if (failed) return; if (code === 0) resolve(output); else reject(new Error(`Lokal prosess avsluttet (${code}). Lydfilene er bevart. Prøv CPU-transkripsjon igjen eller reparer runtime.`)); });
  });
}

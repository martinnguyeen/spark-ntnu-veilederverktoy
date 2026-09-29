import { Analysis, Meeting, time, validateAnalysis } from './domain';
// Copied verbatim from the macOS contract by build.mjs, not a renderer-supplied prompt.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
export const endpoint = 'https://llm.hpc.ntnu.no/v1/chat/completions';
export const models = { mistral: 'mistralai/Mistral-Medium-3.5-128B', kimi: 'moonshotai/Kimi-K2.6', glm: 'Inferact/GLM-5.3-NVFP4', borealis: 'NbAiLab/borealis-27b' };
export function route(tokens: number, borealis: boolean) {
  const automatic = tokens < 8000 ? [models.mistral, models.kimi, models.glm] : tokens < 24000 ? [models.kimi, models.mistral, models.glm] : tokens < 135168 ? [models.glm, models.kimi, models.mistral] : [models.kimi, models.mistral];
  if (tokens >= 174762) throw new Error('Transkripsjonen er for lang for IDUN. Del møtet før analyse.');
  return borealis && tokens < 122880 ? [models.borealis, ...automatic] : automatic;
}
async function request(key: string, body: object, timeout: number, fetcher: typeof fetch) {
  let response: Response;
  try { response = await fetcher(endpoint, { method: 'POST', redirect: 'error', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(timeout) }); }
  catch { throw new Error('Kunne ikke nå IDUN. Koble til eduroam eller NTNU VPN og prøv igjen. Transkripsjonen er bevart.'); }
  if (response.status === 401 || response.status === 403) throw new Error('API-nøkkelen ble avvist. Legg inn en gyldig nøkkel i innstillingene.');
  if (!response.ok) throw new Error(`IDUN svarte med HTTP ${response.status}. Prøv igjen senere.`);
  const data = await response.json() as { choices?: { message?: { content?: string }; finish_reason?: string }[] };
  if (data.choices?.[0]?.finish_reason === 'length') throw new Error('IDUN fullførte ikke referatet. Prøv igjen.');
  const content = data.choices?.[0]?.message?.content;
  if (!content) throw new Error('IDUN svarte uten innhold.');
  return content;
}
export async function testConnection(key: string, fetcher = fetch) {
  await request(key, { model: models.mistral, temperature: 0, max_tokens: 32, messages: [{ role: 'user', content: 'Svar kun med: IDUN fungerer' }] }, 60000, fetcher);
  return 'IDUN fungerer. Ingen møtedata ble sendt i testen.';
}
export async function analyze(meeting: Meeting, key: string, borealis: boolean, confirmed: boolean, promptDirectory: string, status: (text: string) => void, fetcher = fetch): Promise<Analysis> {
  if (confirmed !== true) throw new Error('Analyse krever bekreftelse.');
  const system = await readFile(join(promptDirectory, 'idun-system-prompt.txt'), 'utf8');
  const user = `Analyser transkripsjonen under. Møtekontekst: Tittel: ${meeting.title}. Dato: ${meeting.date}. Deltakere: ikke oppgitt. Formål: ikke oppgitt. Språk: norsk bokmål.\n<transcript>\n${meeting.transcript.map(s => `[${s.id} ${time(s.start)}] ${s.speaker ?? 'Ukjent'}: ${s.text}`).join('\n')}\n</transcript>`;
  let error: unknown;
  for (const model of route(Math.ceil(Buffer.byteLength(system + user) / 4), borealis)) {
    status(`IDUN analyserer med ${model}. Venter på svar …`);
    try {
      const content = await request(key, { model, temperature: 0.1, max_tokens: 8192, messages: [{ role: 'system', content: system }, { role: 'user', content: user }], response_format: { type: 'json_object' } }, 600000, fetcher);
      return validateAnalysis(JSON.parse(content.replace(/^```(?:json)?\s*/, '').replace(/\s*```$/, '')), meeting.transcript);
    } catch (e) { error = e; if ((e as Error).message.includes('API-nøkkelen') || (e as Error).message.includes('VPN')) throw e; }
  }
  throw error;
}

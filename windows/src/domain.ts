export interface Segment { id: string; start: number; end: number; speaker?: string | null; text: string }
export interface Evidence { text: string; confidence?: 'low' | 'medium' | 'high'; evidence_segment_ids: string[] }
export interface Action { task: string; owner: string | null; deadline: string | null; confidence: 'low' | 'medium' | 'high'; evidence_segment_ids: string[] }
export interface Analysis { schema_version: '1.0'; summary: string; key_points: Evidence[]; decisions: Evidence[]; action_items: Action[]; open_questions: Evidence[] }
export type MeetingState = 'idle' | 'recording' | 'finalizing' | 'transcribing' | 'transcriptReady' | 'analyzing' | 'completed' | 'completedWithoutAnalysis';
export interface Meeting { id: string; title: string; date: string; duration: number; state: MeetingState; transcript: Segment[]; analysis?: Analysis | null }
export const states: MeetingState[] = ['idle', 'recording', 'finalizing', 'transcribing', 'transcriptReady', 'analyzing', 'completed', 'completedWithoutAnalysis'];
export function validID(id: unknown): asserts id is string {
  if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error('Ugyldig møte-ID.');
}
export function validateMeeting(value: unknown): Meeting {
  const m = value as Meeting;
  if (!m || typeof m !== 'object') throw new Error('Ugyldig møtedokument.');
  validID(m.id);
  if (typeof m.title !== 'string' || m.title.length > 500 || typeof m.date !== 'string' || !Number.isFinite(Date.parse(m.date)) || !Number.isFinite(m.duration) || m.duration < 0 || !states.includes(m.state) || !Array.isArray(m.transcript)) throw new Error('Ugyldig møteformat.');
  const ids = new Set<string>();
  for (const s of m.transcript) {
    if (!s || typeof s.id !== 'string' || ids.has(s.id) || typeof s.text !== 'string' || !Number.isFinite(s.start) || !Number.isFinite(s.end) || s.start < 0 || s.end < s.start || (s.speaker != null && typeof s.speaker !== 'string')) throw new Error('Ugyldig transkripsjon.');
    ids.add(s.id);
  }
  if (m.analysis) m.analysis = validateAnalysis(m.analysis, m.transcript, 'archive');
  return m;
}
export function validateAnalysis(value: unknown, transcript: Segment[], source: 'idun' | 'archive' = 'idun'): Analysis {
  const a = value as Analysis;
  if (!a || a.schema_version !== '1.0' || typeof a.summary !== 'string') throw new Error('IDUN returnerte ugyldig JSON. Prøv igjen.');
  const ids = new Set(transcript.map(s => s.id));
  for (const key of ['key_points', 'decisions', 'action_items', 'open_questions'] as const) {
    if (!Array.isArray(a[key])) throw new Error('IDUN mangler obligatoriske felt.');
    for (const item of a[key]) {
      if (!item || typeof item !== 'object') throw new Error('Ugyldig analysepunkt.');
      if (source === 'archive') {
        if ('task' in item) { item.owner ??= null; item.deadline ??= null; }
        else if (typeof item.text !== 'string' && typeof (item as unknown as { point?: string }).point === 'string') item.text = (item as unknown as { point: string }).point;
      }
      const text = 'task' in item ? item.task : item.text;
      if (typeof text !== 'string' || !text.trim() || !Array.isArray(item.evidence_segment_ids) || !item.evidence_segment_ids.length || !item.evidence_segment_ids.every(id => ids.has(id))) throw new Error('IDUN returnerte påstander uten gyldige kildeutsagn. Prøv igjen.');
      if (key !== 'open_questions' && !(source === 'archive' && key !== 'action_items' && item.confidence == null) && !['high', 'medium', 'low'].includes(item.confidence ?? '')) throw new Error('Ugyldig sikkerhetsnivå fra IDUN.');
      if ('task' in item && ((item.owner !== null && typeof item.owner !== 'string') || (item.deadline !== null && typeof item.deadline !== 'string'))) throw new Error('Ugyldig eier eller frist.');
    }
  }
  return source === 'archive' ? a : { ...a, decisions: a.decisions.filter(item => !transcript.filter(s => item.evidence_segment_ids.includes(s.id)).some(s => /kanskje|muligens|kan vi|bør vi/i.test(s.text))) };
}
export function baseEntry(m: Meeting): string {
  if (!m.analysis) return m.title;
  const a = m.analysis;
  const lines = [m.title, new Date(m.date).toLocaleDateString('nb-NO', { day: 'numeric', month: 'short', year: 'numeric' }), '', a.summary, ''];
  if (a.key_points.length) lines.push('Dette ble diskutert', '', ...a.key_points.map(i => `• ${i.text}`), '');
  if (a.decisions.length) lines.push('Beslutninger', '', ...a.decisions.map(i => `• ${i.text}`), '');
  const confirmed = a.action_items.filter(i => i.confidence !== 'low');
  if (confirmed.length) lines.push('To-Do', '', ...confirmed.map(i => { const meta = [i.owner, i.deadline].filter(Boolean).join(' – '); return `• ${i.task}${meta ? ` (${meta})` : ''}`; }));
  return lines.join('\n').trim();
}
export function time(seconds: number) { return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${Math.floor(seconds % 60).toString().padStart(2, '0')}`; }
export function markdown(m: Meeting): string {
  const a = m.analysis;
  return [`# ${m.title}`, m.date, '## Oppsummering', a?.summary ?? 'Ingen oppsummering.', '## Dette ble diskutert', ...(a?.key_points.map(i => `- ${i.text}`) ?? []), '## Beslutninger', ...(a?.decisions.map(i => `- ${i.text}`) ?? []), '## Gjøremål', ...(a?.action_items.map(i => `- [ ] ${i.task}${i.owner ? ` — ${i.owner}` : ''}${i.deadline ? ` (${i.deadline})` : ''}${i.confidence === 'low' ? ' [Usikkert]' : ''}`) ?? []), '## Åpne spørsmål', ...(a?.open_questions.map(i => `- ${i.text}`) ?? []), '## Transkripsjon', ...m.transcript.map(s => `[${time(s.start)}] ${s.speaker ?? 'Ukjent'}: ${s.text}`)].join('\n\n');
}
export function searchMeeting(m: Meeting, query: string) { return JSON.stringify([m.title, m.transcript, m.analysis]).toLocaleLowerCase('nb').includes(query.trim().toLocaleLowerCase('nb')); }
export function whisperSegments(value: unknown, offset = 0, prefix = 's'): Segment[] {
  const data = value as { transcription?: { offsets: { from: number; to: number }; text: string }[] };
  if (!Array.isArray(data.transcription)) throw new Error('Whisper returnerte et ukjent format.');
  return data.transcription.filter(s => s.text?.trim()).map((s, i) => {
    if (!Number.isFinite(s.offsets?.from) || !Number.isFinite(s.offsets?.to)) throw new Error('Whisper mangler tidskoder.');
    return { id: `${prefix}${i + 1}`, start: offset + s.offsets.from / 1000, end: offset + s.offsets.to / 1000, speaker: null, text: s.text.trim() };
  });
}

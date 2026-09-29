# Shared contracts

- `meeting.schema.json` documents the macOS `Domain.swift` / `Persistence.swift` wire format. Dates are ISO-8601 strings, times are seconds, IDs are UUIDs, transcript IDs are unique within a meeting. Optional `speaker` and `analysis` may be absent or null. Windows exports JSON that matches these field names and imports JSON as a new local meeting ID to avoid overwriting existing data.
- `model-manifest.json` pins the official model revision, expected byte count and SHA-256, plus a CPU-only Windows x64 runtime release. The SHA-256 of the model matches the existing Mac installer. Runtime hash is from the official GitHub release asset digest. Files are never committed to Git.
- `idun-system-prompt.txt` is extracted verbatim from `MeetingPrompt.system` in the Mac app. Keep the prompt and Swift original synchronized when changing analysis behavior.

Runtime validation additionally checks `end >= start`, unique transcript IDs, and that every evidence reference points to an existing segment. Fresh IDUN analysis requires nonempty evidence and valid confidence levels; tentative decisions are filtered. Archive import accepts Swift's omitted optional owner/deadline/confidence fields and the legacy `point` alias, without refiltering saved decisions. Malformed records remain on disk and appear as an unreadable-record diagnostic.

Unit tests exercise Mac-shaped JSON roundtrips. Actual export → open in the Mac application → re-export → Windows import is still a manual interoperability gate; there is no cross-device sync.

Model attribution: National Library of Norway AI Lab, NB-Whisper small beta, CC BY 4.0. Whisper.cpp is MIT licensed. Electron/Chromium notices are included in the development package. No license for this repository is implied by these third-party licenses.

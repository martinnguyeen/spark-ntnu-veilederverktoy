# ADR 0001: Lokal ASR med NB-Whisper

Status: besluttet.

Møtelyd behandles lokalt med `whisper.cpp` og `NbAiLab/nb-whisper-small-beta`. IDUN mottar bare tekst etter eksplisitt bekreftelse. Dette prioriterer personvern og en enkel, etterprøvbar grense fremfor fjerntranskripsjon. Runtime- og modelltilgjengelighet diagnostiseres eksplisitt; manglende modell skal ikke gi stille fallback til en ekstern tjeneste.

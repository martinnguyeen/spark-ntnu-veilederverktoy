# ADR 0002: Systemlyd er en separat pilotgate

Status: implementert, avventer fysisk pilotgodkjenning.

Mikrofonopptak støttes fra macOS 14. Systemlyd bruker ScreenCaptureKit, utelater appens egen lyd og tidsjusteres med mikrofonen før den går inn i samme gjenopprettbare opptaks- og transkripsjonsløp. Automatisk miksing, routing og tillatelsesfeil er testet. Funksjonen regnes ikke som fysisk pilotgodkjent før tillatelsesflyt og faktiske møter i Teams, Zoom og Meet er kontrollert på målmaskinen.

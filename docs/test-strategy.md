# Teststrategi for pilot

## Automatisert ved hver endring

- Domene- og tilstandsmaskiner for møte, diktering og analyse.
- Segmentgrenser, atomisk manifest, diskplassfeil, krasjgjenoppretting, syv dagers rålydretensjon og 14 dagers retensjon for møteinnhold.
- Stabil sammenføying av segmenttranskripsjoner, evidanse-ID-er og endring av talernavn.
- Lokal persistens, sletting, eksport, import og IDUN-ruting uten ekte nettverk.

## Opt-in integrasjon

- IDUN-tilkobling, modelloversikt og én kontrollert ende-til-ende-oppsummering kjøres bare med eksplisitte miljøvariabler og aktiv NTNU-tilgang.
- Resultatet skal vise faktisk modell, svartid og valideringsutfall. En hoppet test er ikke en bestått test.

## Fysiske pilotporter

- Minst ett 120-minutters møte på målmaskinen, inkludert hvile/oppvåkning, lyddevice-bytte og kontrollert diskpress.
- Den implementerte ScreenCaptureKit-miksingen testes separat i Teams, Zoom og Meet, med både lokal og ekstern taler, tillatelsesavslag og lyddevice-bytte. Test innebygd mikrofon og Bluetooth-mikrofon, og bekreft at møtelyd fra systemutgangen kommer med etter bytte mellom lydruter.
- Hurtigdiktering testes manuelt i Notes, Mail og nettleserfelt.
- Norsk referansesett med samtykke måler ordfeil samt kritiske navn, tall, beslutninger og gjøremål.

Disse fysiske portene kan ikke erstattes av grønne unit-tester.

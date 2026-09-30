# Spark NTNU – veilederverktøy

Installer Spark på Mac med tre steg. Krever macOS 14 eller nyere.

1. **Åpne Terminal.**

2. **Lim inn denne kommandoen og trykk Enter:**

   ```sh
   if [ ! -d "$HOME/spark-ntnu-veilederverktoy/.git" ]; then git clone https://github.com/martinnguyeen/spark-ntnu-veilederverktoy.git "$HOME/spark-ntnu-veilederverktoy"; fi && cd "$HOME/spark-ntnu-veilederverktoy" && ./scripts/install-macos.sh && open "outputs/Spark NTNU veilederverktøy.app"
   ```

3. **Vent mens Spark settes opp.** Første gang lastes Whisper-modellen ned (omtrent 466 MB), appen bygges og åpnes. Hvis macOS ber deg installere Command Line Tools, fullfør installasjonen og lim inn kommandoen én gang til. Når Spark åpnes, bruk eduroam eller NTNU VPN og lim inn IDUN API-nøkkelen din.

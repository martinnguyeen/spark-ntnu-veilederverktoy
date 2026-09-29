param([switch]$CheckOnly, [switch]$NoLaunch, [switch]$ProvisionModel)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -notin @('AMD64', 'x86')) { throw 'Denne versjonen krever Windows 11 x64.' }
if ([Environment]::OSVersion.Version.Build -lt 22000) { throw 'Windows 11 er nødvendig.' }
$repoPath = Split-Path -Parent $PSScriptRoot
$clientPath = Join-Path $repoPath 'windows'
$toolsPath = Join-Path $env:LOCALAPPDATA 'SparkNTNU-Tools'
$nodeVersion = '22.23.3'
$nodeFolder = Join-Path $toolsPath "node-v$nodeVersion-win-x64"
$nodeExe = Join-Path $nodeFolder 'node.exe'
$nodeZip = Join-Path $toolsPath "node-v$nodeVersion-win-x64.zip"
$nodeHash = '2b0ff57b049cda1bbcea2240eec20467018713c1efe1f7360c2681859b90ed71'
Write-Host 'Spark NTNU for Windows — utvikleroppsett'
Write-Host "Programdata: $(Join-Path $env:LOCALAPPDATA 'SparkNTNU')"
if ($CheckOnly) {
    Write-Host "Windows build: $([Environment]::OSVersion.Version.Build)"
    Write-Host "Node tilgjengelig: $(Test-Path -LiteralPath $nodeExe)"
    Write-Host "Bygget app tilgjengelig: $(Test-Path -LiteralPath (Join-Path $clientPath 'dist/main.cjs'))"
    Write-Host 'Start appen og velg Kontroller filer for full SHA-256-kontroll av modell og runtime.'
    exit 0
}
New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
if (-not (Test-Path -LiteralPath $nodeExe)) {
    Write-Host "Laster ned Node $nodeVersion til din brukerkonto …"
    Invoke-WebRequest -Uri "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-win-x64.zip" -OutFile $nodeZip
    if ((Get-FileHash -LiteralPath $nodeZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nodeHash) { throw 'Node-kontrollsummen stemmer ikke. Kjør oppsettet på nytt.' }
    Expand-Archive -LiteralPath $nodeZip -DestinationPath $toolsPath -Force
}
$env:PATH = "$nodeFolder;$env:PATH"
$npmCli = Join-Path $nodeFolder 'node_modules/npm/bin/npm-cli.js'
Push-Location $clientPath
try {
    # A pinned pnpm and frozen lockfile make the development dependency graph reproducible.
    & $nodeExe $npmCli exec --yes --package=pnpm@11.25.0 -- pnpm install --frozen-lockfile --ignore-scripts
    if ($LASTEXITCODE -ne 0) { throw 'Installasjon av avhengigheter feilet. Kontroller internett og prøv igjen.' }
    & $nodeExe 'node_modules/electron/install.js'
    if ($LASTEXITCODE -ne 0) { throw 'Nedlasting av Electron feilet.' }
    & $nodeExe 'node_modules/typescript/bin/tsc' --noEmit
    if ($LASTEXITCODE -ne 0) { throw 'Typesjekk feilet.' }
    & $nodeExe 'scripts/build.mjs'
    if ($LASTEXITCODE -ne 0) { throw 'Bygging feilet.' }
    if ($ProvisionModel) {
        & $nodeExe --import tsx 'scripts/provision.mts'
        if ($LASTEXITCODE -ne 0) { throw 'Whisper-oppsettet feilet. Du kan prøve igjen fra innstillingene i appen.' }
    }
    & $nodeExe 'scripts/package.mjs'
    if ($LASTEXITCODE -ne 0) { throw 'Pakking feilet.' }
    $latestPackage = Get-ChildItem -LiteralPath (Join-Path $clientPath 'release') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $appPath = Join-Path $latestPackage.FullName 'Spark NTNU.exe'
    Write-Host "Ferdig. Start appen: $appPath"
    Write-Host 'Første transkripsjon krever ca. 470 MiB nedlasting fra appens innstillinger. NTNU VPN er ikke nødvendig for nedlasting.'
    if (-not $NoLaunch) { Start-Process -FilePath $appPath -WindowStyle Hidden }
} finally { Pop-Location }

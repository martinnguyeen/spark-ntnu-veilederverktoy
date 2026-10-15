# Compatibility entry point for previously shared installation commands.
param([switch]$CheckOnly, [switch]$NoLaunch, [switch]$ProvisionModel)
$ErrorActionPreference = 'Stop'
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/scripts/install-windows.ps1') @PSBoundParameters

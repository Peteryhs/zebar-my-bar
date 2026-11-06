# Read-only diagnosis by default; -Repair repairs only lost docking/topmost state.
param(
  [string]$BarTitle = 'Zebar - my-bar / vanilla',
  [switch]$Repair
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'bar-dock.cs')
. (Join-Path $PSScriptRoot 'bar-dock-config.ps1')
$logicalHeight = Get-BarDockHeight
$states = @([ZebarDock.Guard]::Check($BarTitle, $Repair.IsPresent, $logicalHeight))
if ($Repair -and @($states | Where-Object { $_.Repair -eq 'waiting for bar geometry to settle' }).Count -gt 0) {
  Start-Sleep -Milliseconds 1100
  $states = @([ZebarDock.Guard]::Check($BarTitle, $true, $logicalHeight))
}
$states | ConvertTo-Json -Depth 4

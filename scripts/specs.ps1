# specs.ps1
#
# Prints one JSON object describing this machine, for the About panel.
#
# Everything here is the part zebar's providers do not carry: the model name, the
# graphics adapters, the Windows edition and feature update, the serial. Live
# figures (load, memory in use, free disk) come from the providers instead, so
# this runs once when the panel opens and is never polled.
#
# Every lookup is individually optional. A machine that reports no serial, or a
# virtual machine with no real model, should still show everything else rather
# than turning the whole panel into an error.

$ErrorActionPreference = 'SilentlyContinue'

function Get-First($items, [string]$property) {
  if (-not $items) { return $null }

  $value = @($items)[0].$property

  if ($null -eq $value) { return $null }

  $text = ([string]$value).Trim()

  if ($text -eq '') { return $null }

  return $text
}

$system = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor
$baseboard = Get-CimInstance Win32_BaseBoard

# The display version ("24H2") is not in any WMI class, only in the registry.
$displayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion

# Real adapters only. A remote or headless session lists the basic display
# adapter alongside them, which tells the reader nothing.
$graphics = @(
  Get-CimInstance Win32_VideoController |
    Where-Object { $_.Name -and $_.Name -notmatch 'Basic Display|Basic Render|Remote Display' } |
    ForEach-Object { $_.Name.Trim() }
)

$manufacturer = Get-First $system 'Manufacturer'
$model = Get-First $system 'Model'

# Consumer laptops often put the useful name in the baseboard product instead.
if (-not $model) { $model = Get-First $baseboard 'Product' }

[pscustomobject]@{
  deviceName   = Get-First $system 'Name'
  manufacturer = $manufacturer
  model        = $model
  processor    = Get-First $cpu 'Name'
  graphics     = $graphics
  osName       = Get-First $os 'Caption'
  osVersion    = $displayVersion
  osBuild      = Get-First $os 'BuildNumber'
  architecture = Get-First $os 'OSArchitecture'
  serial       = Get-First $bios 'SerialNumber'
  biosVersion  = Get-First $bios 'SMBIOSBIOSVersion'
} | ConvertTo-Json -Compress -Depth 3

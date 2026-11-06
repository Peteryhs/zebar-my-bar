# Run on an interactive Windows desktop with Zebar open.
# Default: inspect health only. -ExerciseRecovery briefly removes the real bar's
# reservation and topmost style, repairs them, and restores them in finally.
param(
  [string]$BarTitle = 'Zebar - my-bar / vanilla',
  # Run deterministic repair regressions without changing desktop windows.
  [switch]$RegressionOnly,
  [switch]$ExerciseRecovery,
  # Do not call the repair method after injecting a failure; wait for the
  # actual helper started by vanilla.html to repair it in the background.
  [switch]$ObserveAutomaticRecovery
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bar-dock-config.ps1')
$logicalHeight = Get-BarDockHeight
$guardSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bar-dock.cs') -Raw
$testSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'test-bar-dock.cs') -Raw
Add-Type -TypeDefinition ($guardSource + [Environment]::NewLine + $testSource)
[ZebarDock.Tests.Regression]::Run($logicalHeight) | Write-Output
if ($RegressionOnly) { return }

function Assert-Healthy($states) {
  if (@($states).Count -eq 0) { throw 'No matching Zebar bar is visible.' }
  foreach ($state in $states) {
    if (-not $state.Reserved -or -not $state.TopMost) {
      throw ('Unhealthy bar: ' + ($state | ConvertTo-Json -Depth 4 -Compress))
    }
  }
}

function Wait-Healthy {
  # Explorer can publish rcWork asynchronously after ABM_SETPOS returns.
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    $states = @([ZebarDock.Guard]::Check($BarTitle, $false, $logicalHeight))
    if ($states.Count -gt 0 -and @($states | Where-Object { -not $_.Reserved -or -not $_.TopMost }).Count -eq 0) {
      return $states
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  Assert-Healthy $states
}

if ($ExerciseRecovery) {
  [void][ZebarDock.Guard]::Check($BarTitle, $true, $logicalHeight)
  [void](Wait-Healthy)
}
$baseline = @([ZebarDock.Guard]::Check($BarTitle, $false, $logicalHeight))
Assert-Healthy $baseline
if (@([ZebarDock.Guard]::Check($BarTitle + ' does-not-exist', $false, $logicalHeight)).Count -ne 0) {
  throw 'Title matching must be exact.'
}
Write-Output ('PASS: {0} bar(s) topmost and reserved; exact-title isolation.' -f $baseline.Count)
if (-not $ExerciseRecovery) { return }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DockTestNative {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA {
    public uint cbSize; public IntPtr hWnd; public uint Callback, Edge;
    public RECT Rect; public IntPtr Param;
  }
  [DllImport("shell32.dll")] public static extern UIntPtr SHAppBarMessage(uint message, ref APPBARDATA data);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
'@

try {
  foreach ($bar in $baseline) {
    foreach ($scenario in @('topmost', 'registered-empty-reservation', 'missing-registration', 'combined')) {
    $data = New-Object DockTestNative+APPBARDATA
    $data.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($data)
    $data.hWnd = [IntPtr]$bar.Handle
    if ($scenario -eq 'registered-empty-reservation') {
      $data.Edge = 1
      $data.Rect.Left = $bar.Monitor.Left
      $data.Rect.Top = $bar.Monitor.Top
      $data.Rect.Right = $bar.Monitor.Right
      $data.Rect.Bottom = $bar.Monitor.Top
      [void][DockTestNative]::SHAppBarMessage(3, [ref]$data) # ABM_SETPOS, same HWND still registered
    } elseif ($scenario -ne 'topmost') {
      [void][DockTestNative]::SHAppBarMessage(1, [ref]$data) # ABM_REMOVE
    }
    if ($scenario -in @('topmost', 'combined')) {
      [void][DockTestNative]::SetWindowPos($data.hWnd, [IntPtr](-2), 0, 0, 0, 0, 0x13)
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      $broken = @([ZebarDock.Guard]::Check($BarTitle, $false, $logicalHeight)) | Where-Object Handle -eq $bar.Handle
      $reservationLost = $scenario -eq 'topmost' -or -not $broken.Reserved
      $topmostLost = $scenario -notin @('topmost', 'combined') -or -not $broken.TopMost
      if ($reservationLost -and $topmostLost) { break }
      Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $reservationLost -or -not $topmostLost) { throw 'Windows did not publish the injected failure.' }
    if (-not $ObserveAutomaticRecovery) { [void][ZebarDock.Guard]::Check($BarTitle, $true, $logicalHeight) }
    $repaired = @(Wait-Healthy)
    Assert-Healthy $repaired
    Write-Output ('PASS: {0} recovered for HWND {1}.' -f $scenario, $bar.Handle)
    }
  }

  for ($iteration = 0; $iteration -lt 20; $iteration++) {
    $states = @([ZebarDock.Guard]::Check($BarTitle, $true, $logicalHeight))
    Assert-Healthy $states
    foreach ($state in $states) {
      $original = $baseline | Where-Object Handle -eq $state.Handle
      if ($state.Repair -ne '' -or
          ($state.Bounds | ConvertTo-Json -Compress) -ne ($original.Bounds | ConvertTo-Json -Compress) -or
          ($state.Work | ConvertTo-Json -Compress) -ne ($original.Work | ConvertTo-Json -Compress)) {
        throw 'Repeated checks changed a healthy reservation or its geometry.'
      }
    }
  }
  Write-Output 'PASS: 20 repeated checks caused no duplicate reservation, geometry drift or z-order changes.'
} finally {
  [void][ZebarDock.Guard]::Check($BarTitle, $true, $logicalHeight)
  Assert-Healthy @(Wait-Healthy)
}

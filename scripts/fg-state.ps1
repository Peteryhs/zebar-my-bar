# fg-state.ps1
#
# Prints "max" while the foreground window is maximized and "float" otherwise.
# Only prints when the state changes, one line per change, so the widget can
# read it with onStdout.
#
# Used by vanilla.html to decide whether the bar fills its whole strip
# (maximized window) or lifts off the screen edge (nothing maximized).
#
# Spawned by Zebar with CREATE_NO_WINDOW, so no console window appears.
# Exits by itself if Zebar is gone, so a crash cannot leave it behind.

param(
  [int]$IntervalMs = 250
)

# Clean up watchers left behind by earlier widget instances. A widget relaunch
# does not always run the page's unload handler, so without this, stale copies
# pile up (the newest wins, any older one stops updating its widget).
$selfScript = $MyInvocation.MyCommand.Path
try {
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
    Where-Object {
      $_.ProcessId -ne $PID -and $_.CommandLine -like "*$selfScript*"
    } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
} catch {
  # Process listing unavailable: keep going, an extra watcher is harmless.
}

Add-Type -Namespace ZebarFg -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
'@

# Shell surfaces are not "windows" for our purpose: if one of these has focus,
# the bar floats like it does on the bare desktop.
$shellClasses = @(
  'Progman',
  'WorkerW',
  'SysListView32',
  'Shell_TrayWnd',
  'Shell_SecondaryTrayWnd',
  'Windows.UI.Core.CoreWindow',
  'XamlExplorerHostIslandWindow'
)

$last = ''
$ticks = 0

while ($true) {
  $state = 'float'
  $h = [ZebarFg.Native]::GetForegroundWindow()

  if ($h -ne [System.IntPtr]::Zero) {
    $classBuffer = New-Object System.Text.StringBuilder 256
    [void][ZebarFg.Native]::GetClassName($h, $classBuffer, 256)
    $className = $classBuffer.ToString()

    if (($shellClasses -notcontains $className) -and
        [ZebarFg.Native]::IsWindowVisible($h)) {
      if ([ZebarFg.Native]::IsZoomed($h)) {
        $state = 'max'
      }
    }
  }

  if ($state -ne $last) {
    $last = $state
    try {
      [Console]::Out.WriteLine($state)
      [Console]::Out.Flush()
    } catch {
      # stdout pipe is gone, nobody is listening any more
      break
    }
  }

  # Cheap liveness check every ~10 seconds.
  $ticks++
  if ($ticks -ge 40) {
    $ticks = 0
    if (-not (Get-Process -Name zebar -ErrorAction SilentlyContinue)) {
      break
    }
  }

  Start-Sleep -Milliseconds $IntervalMs
}

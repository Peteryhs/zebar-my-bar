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
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
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

# Zebar's own windows are not an answer to "what is the user working in". The bar
# and every panel take the foreground when clicked, and since neither is
# maximized the state used to flip to "float" the moment the bar was touched: the
# bar lifted off the edge while the maximized window behind it had not moved.
# When one of our own windows has the focus, the last state stands.
#
# A widget's window belongs to a WebView2 child process, not to zebar.exe, and
# plenty of other applications use WebView2 too: the process name alone is not
# enough, so the parent chain is walked up to zebar. The answer is memoised per
# process id, because this runs four times a second and the same handful of
# windows take the foreground over and over.
$ownerCache = @{}

function Test-OwnProcess([uint32]$processId) {
  if ($processId -eq 0) { return $false }
  if ($ownerCache.ContainsKey($processId)) { return $ownerCache[$processId] }

  $isOurs = $false
  $current = $processId

  # zebar -> msedgewebview2 -> its own utility children is three levels at most.
  for ($hop = 0; $hop -lt 4 -and $current -ne 0; $hop++) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue

    if (-not $process) { break }

    if ($process.Name -eq 'zebar.exe') {
      $isOurs = $true
      break
    }

    $current = [uint32]$process.ParentProcessId
  }

  $ownerCache[$processId] = $isOurs

  return $isOurs
}

function Test-OwnWindow($handle) {
  $ownerPid = [uint32]0
  [void][ZebarFg.Native]::GetWindowThreadProcessId($handle, [ref]$ownerPid)

  return Test-OwnProcess $ownerPid
}

$last = ''
$ticks = 0

while ($true) {
  $state = $null
  $h = [ZebarFg.Native]::GetForegroundWindow()

  if ($h -eq [System.IntPtr]::Zero) {
    $state = 'float'
  } elseif (Test-OwnWindow $h) {
    # The bar or one of its panels. Report nothing and leave the bar as it is.
    $state = $last
  } else {
    $state = 'float'

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

  if ($state -and $state -ne $last) {
    $last = $state
    try {
      [Console]::Out.WriteLine($state)
      [Console]::Out.Flush()
    } catch {
      # stdout pipe is gone, nobody is listening any more
      break
    }
  }

  # Cheap liveness check every ~10 seconds. The ownership answers are dropped at
  # the same time: Windows reuses process ids, and a remembered "that one is
  # ours" would then hold the bar in the wrong state for as long as the cache
  # lived. Re-deciding costs one WMI lookup per window that takes the focus.
  $ticks++
  if ($ticks -ge 40) {
    $ticks = 0
    $ownerCache.Clear()

    if (-not (Get-Process -Name zebar -ErrorAction SilentlyContinue)) {
      break
    }
  }

  Start-Sleep -Milliseconds $IntervalMs
}

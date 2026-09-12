# window-ctl.ps1 -Action close|guard -Match "<widget name>[,<name>...]"
#
# Widget windows of one pack cannot reach each other through the client API, so
# this helper works on them from the outside. It finds top level windows that
# belong to zebar.exe and carry a widget name in their title. Zebar titles widget
# windows "Zebar - <pack id> / <widget name>", and matching on the widget name
# alone keeps working if that format ever changes.
#
#   close  Closes every match and prints how many it closed (0 if none).
#   guard  Long lived. Watches every named panel in one process and closes one as
#          soon as it is dismissed. Reports what it does on stdout, one event per
#          line, which is how the bar knows whether a panel is up:
#
#            open <name>      a panel window appeared
#            closed <name>    the guard closed it
#            gone <name>      it disappeared on its own
#
# A panel is dismissed by a mouse click outside it, and by nothing else. Focus
# changes and the pointer resting elsewhere both close popups the user never asked
# to close: Windows hands focus to a new window and takes it away again for
# reasons that are invisible from here, and a panel that vanishes a second after
# opening is the result.
#
# Detecting the click here, from the mouse state, rather than in the panel's page
# is deliberate. It does not depend on which window has the focus, or on a page
# receiving an event, both of which turned out to be unreliable.
#
# Closing happens here too, with WM_CLOSE after fading the window, so it never
# depends on the page being able to close itself.
#
# A trace file lives at %TEMP%\zebar-window-ctl.log.

param(
  [Parameter(Mandatory = $true)][ValidateSet('close', 'guard')][string]$Action,
  [Parameter(Mandatory = $true)][string]$Match,
  [string]$Owner = 'default',
  [int]$TickMs = 100,
  [int]$ScanMs = 300,
  [int]$GraceMs = 250,
  [int]$MaxLifetimeMinutes = 240
)

Add-Type -Namespace ZebarWin -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint message, System.IntPtr wParam, System.IntPtr lParam, uint flags, uint timeout, out System.IntPtr result);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr hWnd, int index);
[DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr hWnd, int index, int value);
[DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(System.IntPtr hWnd, uint colorKey, byte alpha, uint flags);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr insertAfter, int x, int y, int width, int height, uint flags);
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

$WM_CLOSE = 0x0010
$SMTO_ABORTIFHUNG = 0x0002
$GWL_EXSTYLE = -20
$WS_EX_LAYERED = 0x00080000
$LWA_ALPHA = 0x00000002
$SWP_NOSIZE = 0x0001
$SWP_NOZORDER = 0x0004
$SWP_NOACTIVATE = 0x0010

$logPath = Join-Path $env:TEMP 'zebar-window-ctl.log'

$matchNames = @($Match -split ',' |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -ne '' })

function Write-Trace([string]$message) {
  try {
    Add-Content -Path $logPath -Value (
      '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $message
    ) -ErrorAction Stop
  } catch {
    # Tracing is best effort.
  }
}

function Write-Event([string]$message) {
  try {
    [Console]::Out.WriteLine($message)
    [Console]::Out.Flush()
  } catch {
    # Nobody is listening any more.
  }
}

function Get-TargetWindows {
  $found = New-Object System.Collections.ArrayList

  $callback = [ZebarWin.Native+EnumWindowsProc]{
    param($hWnd, $lParam)

    if (-not [ZebarWin.Native]::IsWindowVisible($hWnd)) {
      return $true
    }

    $title = New-Object System.Text.StringBuilder 512
    [void][ZebarWin.Native]::GetWindowTextW($hWnd, $title, 512)
    $titleText = $title.ToString()

    $matched = $false

    foreach ($name in $matchNames) {
      if ($titleText -like "*$name*") {
        $matched = $true
        break
      }
    }

    if (-not $matched) {
      return $true
    }

    # Only titles that already match are checked against the process, so the scan
    # does not need to enumerate every process on the machine.
    $ownerPid = 0
    [void][ZebarWin.Native]::GetWindowThreadProcessId($hWnd, [ref]$ownerPid)
    $owner = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue

    if ($owner -and $owner.ProcessName -eq 'zebar') {
      [void]$found.Add($hWnd)
    }

    return $true
  }

  [void][ZebarWin.Native]::EnumWindows($callback, [System.IntPtr]::Zero)
  return $found
}

function Get-WindowName($handle) {
  $title = New-Object System.Text.StringBuilder 512
  [void][ZebarWin.Native]::GetWindowTextW([System.IntPtr]$handle, $title, 512)
  $titleText = $title.ToString()

  foreach ($name in $matchNames) {
    if ($titleText -like "*$name*") {
      return $name
    }
  }

  return 'unknown'
}

# Fade the window out, then close it. The fade is done here, on the window, rather
# than by asking the page to animate: a panel that is being dismissed may not be
# in a position to run anything, and a window that simply vanishes looks broken.
function Close-Window([int64]$handle) {
  $hwnd = [System.IntPtr]$handle

  try {
    $rect = New-Object ZebarWin.Native+RECT
    [void][ZebarWin.Native]::GetWindowRect($hwnd, [ref]$rect)

    $style = [ZebarWin.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE)

    if (($style -band $WS_EX_LAYERED) -eq 0) {
      [void][ZebarWin.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -bor $WS_EX_LAYERED)
    }

    # About 120ms of fade, lifting a few pixels as it goes.
    foreach ($step in 1..6) {
      $alpha = [byte](255 - ($step * 42))
      [void][ZebarWin.Native]::SetLayeredWindowAttributes($hwnd, 0, $alpha, $LWA_ALPHA)
      [void][ZebarWin.Native]::SetWindowPos($hwnd, [System.IntPtr]::Zero, $rect.Left, ($rect.Top - $step), 0, 0,
        ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE))
      Start-Sleep -Milliseconds 20
    }
  } catch {
    # The fade is cosmetic: closing still has to happen.
  }

  $result = [System.IntPtr]::Zero
  [void][ZebarWin.Native]::SendMessageTimeout(
    $hwnd, $WM_CLOSE, [System.IntPtr]::Zero,
    [System.IntPtr]::Zero, $SMTO_ABORTIFHUNG, 2000, [ref]$result)
}

# Bit 0x0001 means "pressed since the previous call", so a click that lands
# between two polls is still caught. Every button is read every time rather than
# stopping at the first hit: an unread bit stays set and reads as a click later.
function Test-ClickedSinceLastCheck {
  $pressed = $false

  foreach ($virtualKey in 0x01, 0x02, 0x04) {
    if (([ZebarWin.Native]::GetAsyncKeyState($virtualKey) -band 0x0001) -ne 0) {
      $pressed = $true
    }
  }

  return $pressed
}

function Test-PointerInsideWindow([int64]$handle) {
  $point = New-Object ZebarWin.Native+POINT
  $rect = New-Object ZebarWin.Native+RECT
  [void][ZebarWin.Native]::GetCursorPos([ref]$point)
  [void][ZebarWin.Native]::GetWindowRect([System.IntPtr]$handle, [ref]$rect)

  return ($point.X -ge $rect.Left -and $point.X -lt $rect.Right -and
          $point.Y -ge $rect.Top -and $point.Y -lt $rect.Bottom)
}

if ($Action -eq 'close') {
  $closed = 0
  $targets = Get-TargetWindows

  foreach ($handle in $targets) {
    Close-Window ([int64]$handle)
    $closed++
  }

  Write-Event $closed
  Write-Trace ('close match={0} closed={1}' -f $Match, $closed)
  exit 0
}

# -Action guard
#
# One guard per bar. The bar passes an -Owner identifying the display it sits on,
# so two bars (one per monitor) do not retire each other, while a reloaded bar
# takes over its own display's guard. A pid file beats asking WMI for process
# command lines, which costs seconds.
$ownerKey = ($Owner -replace '[^A-Za-z0-9._-]', '_')
$pidFile = Join-Path $env:TEMP ('zebar-panel-guard-' + $ownerKey + '.pid')

try {
  [System.IO.File]::WriteAllText($pidFile, [string]$PID)
} catch {
  # Without the file the guard still works, it just cannot retire itself.
}

# stdin is read only to notice the bar going away: when the bar's page is gone the
# pipe closes and the read returns null.
#
# The bar does not send commands here. It used to, and they never arrived: zebar's
# shellWrite resolves without delivering anything, so the write looked fine from
# the page while this process saw nothing. Everything the bar needs is either a
# one-shot `-Action close` or something this guard works out for itself.
$stdin = New-Object System.IO.StreamReader ([Console]::OpenStandardInput())
$pendingRead = $stdin.ReadLineAsync()

$lastScan = (Get-Date).AddYears(-1)
$active = @()
# A closed window can linger for a moment, so remember what we just closed to
# avoid attaching to it again on the next scan.
$recentlyClosed = @{}
$tick = 0
$lifeDeadline = (Get-Date).AddMinutes($MaxLifetimeMinutes)

Write-Trace ('guard start names={0} pid={1} owner={2}' -f ($matchNames -join '|'), $PID, $ownerKey)

while ($true) {
  $tick++

  if ($pendingRead.IsCompleted) {
    $line = ''

    try {
      $line = $pendingRead.Result
    } catch {
      $line = ''
    }

    if ($null -eq $line) {
      Write-Trace 'guard exit: stdin closed'
      break
    }

    $pendingRead = $stdin.ReadLineAsync()
  }

  $clicked = Test-ClickedSinceLastCheck
  $now = Get-Date

  foreach ($entry in @($active)) {
    if (-not [ZebarWin.Native]::IsWindow([System.IntPtr]$entry.Handle)) {
      Write-Event ('gone {0}' -f $entry.Name)
      Write-Trace ('guard detach name={0} reason=window-gone' -f $entry.Name)
      $active = @($active | Where-Object { $_ -ne $entry })
      continue
    }

    # Ignore the click that opened the panel, which is still in flight when the
    # window first appears.
    if (($now - $entry.AttachedAt).TotalMilliseconds -lt $GraceMs) {
      continue
    }

    if ($clicked -and -not (Test-PointerInsideWindow $entry.Handle)) {
      Close-Window $entry.Handle
      $recentlyClosed[[string]$entry.Handle] = $now
      Write-Event ('closed {0}' -f $entry.Name)
      Write-Trace ('guard closed name={0} reason=click-outside' -f $entry.Name)
      $active = @($active | Where-Object { $_ -ne $entry })
    }
  }

  # Attach to new panels at a slower cadence: enumerating windows is the
  # expensive part.
  if (($now - $lastScan).TotalMilliseconds -ge $ScanMs) {
    $lastScan = $now

    foreach ($key in @($recentlyClosed.Keys)) {
      if (($now - $recentlyClosed[$key]).TotalSeconds -gt 5) {
        $recentlyClosed.Remove($key)
      }
    }

    foreach ($handle in (Get-TargetWindows)) {
      $alreadyWatched = $false

      foreach ($entry in $active) {
        if ($entry.Handle -eq [int64]$handle) {
          $alreadyWatched = $true
          break
        }
      }

      if ($alreadyWatched -or $recentlyClosed.ContainsKey([string][int64]$handle)) {
        continue
      }

      $name = Get-WindowName ([int64]$handle)

      # One panel at a time. This is the only place that sees a panel however it
      # was opened, including from the command line or by another widget.
      foreach ($other in @($active)) {
        Close-Window $other.Handle
        $recentlyClosed[[string]$other.Handle] = $now
        Write-Event ('closed {0}' -f $other.Name)
        Write-Trace ('guard closed name={0} reason=replaced-by-{1}' -f $other.Name, $name)
      }

      $active = @(
        [PSCustomObject]@{
          Name       = $name
          Handle     = [int64]$handle
          AttachedAt = $now
        }
      )

      [void](Test-ClickedSinceLastCheck) # swallow the click that opened it
      Write-Event ('open {0}' -f $name)
      Write-Trace ('guard attach name={0}' -f $name)
    }
  }

  # Every ~5 seconds: step aside if a newer guard for this display claimed the pid
  # file, exit if Zebar is gone, and give up after the lifetime cap so a stray
  # guard cannot linger forever (the bar starts a fresh one).
  if (($tick % 50) -eq 0) {
    $claimedOwner = ''

    try {
      $claimedOwner = [System.IO.File]::ReadAllText($pidFile).Trim()
    } catch {
      $claimedOwner = ''
    }

    if ($claimedOwner -ne '' -and $claimedOwner -ne [string]$PID) {
      Write-Trace ('guard exit: superseded by pid {0}' -f $claimedOwner)
      break
    }

    if ((Get-Date) -gt $lifeDeadline) {
      Write-Trace ('guard exit: lifetime cap {0} min' -f $MaxLifetimeMinutes)
      break
    }

    if (-not (Get-Process -Name zebar -ErrorAction SilentlyContinue)) {
      Write-Trace 'guard exit: zebar gone'
      break
    }
  }

  Start-Sleep -Milliseconds $TickMs
}

exit 0

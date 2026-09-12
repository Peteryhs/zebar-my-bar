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
  [int]$TickMs = 20,
  [int]$ScanMs = 300,
  [int]$GraceMs = 250,
  [int]$HousekeepingMs = 5000,
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

  # Whether WM_CLOSE was actually honoured. A window that survives it but has
  # already been reported closed is invisible to everything upstream: the panel
  # stays on screen, the bar believes it is gone, and the next click is spent
  # discovering that. Traced so it can never be a silent assumption again.
  Start-Sleep -Milliseconds 120
  $survived = [ZebarWin.Native]::IsWindow($hwnd)

  if ($survived) {
    Write-Trace ('  WM_CLOSE ignored, window {0} still alive' -f $handle)
  }

  return (-not $survived)
}

# Is any mouse button down right now.
#
# The high bit is the button's actual state and is true for as long as the button
# is held. The low bit of the same call means "pressed since the previous call",
# which is the obvious thing to use here and is why clicks went missing: Windows
# documents it as unreliable, and the reason is that it is cleared by whichever
# caller reads it next. Any other process on the machine polling input consumes the
# press before this one gets its turn, so a click would be silently lost, at random,
# and the panel needed clicking again.
#
# The press edge is worked out below instead, from this state, which nothing else
# can take away.
function Test-ButtonDown {
  foreach ($virtualKey in 0x01, 0x02, 0x04) {
    if (([ZebarWin.Native]::GetAsyncKeyState($virtualKey) -band 0x8000) -ne 0) {
      return $true
    }
  }

  return $false
}

function Get-CursorPoint {
  $point = New-Object ZebarWin.Native+POINT
  [void][ZebarWin.Native]::GetCursorPos([ref]$point)

  return $point
}

function Get-WindowRect([int64]$handle) {
  $rect = New-Object ZebarWin.Native+RECT
  [void][ZebarWin.Native]::GetWindowRect([System.IntPtr]$handle, [ref]$rect)

  return $rect
}

function Test-PointInsideRect($point, $rect) {
  return ($point.X -ge $rect.Left -and $point.X -lt $rect.Right -and
          $point.Y -ge $rect.Top -and $point.Y -lt $rect.Bottom)
}

function Test-PointerInsideWindow([int64]$handle) {
  return Test-PointInsideRect (Get-CursorPoint) (Get-WindowRect $handle)
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
$lastHousekeeping = Get-Date
# Whether a mouse button was down on the previous poll, which is how a press is
# told from a hold.
$wasButtonDown = Test-ButtonDown
$active = @()
# A closed window can linger for a moment, so remember what we just closed to
# avoid attaching to it again on the next scan.
$recentlyClosed = @{}
$lifeDeadline = (Get-Date).AddMinutes($MaxLifetimeMinutes)

Write-Trace ('guard start names={0} pid={1} owner={2}' -f ($matchNames -join '|'), $PID, $ownerKey)

while ($true) {
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

  # A click is the moment a button goes from up to down. Watching the state means
  # the poll has to be quick enough to land inside the press: a click is held for
  # something like 50 to 150ms, so $TickMs is 20 rather than 100.
  $buttonDown = Test-ButtonDown
  $clicked = $buttonDown -and -not $wasButtonDown
  $wasButtonDown = $buttonDown

  $now = Get-Date

  # Every click this process sees is written down, whatever it decides to do
  # about it, along with everything the decision was made from. A click that is
  # detected and deliberately dropped and a click that is never detected at all
  # look identical from the far side of the screen, and telling those two apart
  # is the whole difficulty.
  if ($clicked) {
    $point = Get-CursorPoint

    if ($active.Count -eq 0) {
      Write-Trace ('CLICK at {0},{1} -> no panel is being watched' -f $point.X, $point.Y)
    }

    foreach ($entry in @($active)) {
      $rect = Get-WindowRect $entry.Handle
      $inside = Test-PointInsideRect $point $rect
      $age = [int]($now - $entry.AttachedAt).TotalMilliseconds

      $verdict = if ($age -lt $GraceMs) {
        "ignored, within the {0}ms grace after opening" -f $GraceMs
      } elseif ($inside) {
        'ignored, inside the panel'
      } else {
        'dismissing'
      }

      Write-Trace (
        'CLICK at {0},{1} panel={2} hwnd={3} rect={4},{5}-{6},{7} inside={8} age={9}ms -> {10}' -f
          $point.X, $point.Y, $entry.Name, $entry.Handle,
          $rect.Left, $rect.Top, $rect.Right, $rect.Bottom,
          $inside, $age, $verdict)
    }
  }

  foreach ($entry in @($active)) {
    if (-not [ZebarWin.Native]::IsWindow([System.IntPtr]$entry.Handle)) {
      Write-Event ('gone {0}' -f $entry.Name)
      Write-Trace ('guard detach name={0} hwnd={1} reason=window-gone' -f $entry.Name, $entry.Handle)
      $active = @($active | Where-Object { $_ -ne $entry })
      continue
    }

    # Ignore the click that opened the panel, which is still in flight when the
    # window first appears.
    if (($now - $entry.AttachedAt).TotalMilliseconds -lt $GraceMs) {
      continue
    }

    if ($clicked -and -not (Test-PointerInsideWindow $entry.Handle)) {
      $died = Close-Window $entry.Handle
      $recentlyClosed[[string]$entry.Handle] = $now
      Write-Event ('closed {0}' -f $entry.Name)
      Write-Trace ('guard closed name={0} hwnd={1} reason=click-outside died={2}' -f $entry.Name, $entry.Handle, $died)
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
        $died = Close-Window $other.Handle
        $recentlyClosed[[string]$other.Handle] = $now
        Write-Event ('closed {0}' -f $other.Name)
        Write-Trace ('guard closed name={0} hwnd={1} reason=replaced-by-{2} died={3}' -f $other.Name, $other.Handle, $name, $died)
      }

      $active = @(
        [PSCustomObject]@{
          Name       = $name
          Handle     = [int64]$handle
          AttachedAt = $now
        }
      )

      # Swallow the click that opened the panel: if the button is still held, take
      # the current state as the baseline so releasing it cannot read as a new
      # press. The grace period below covers the rest.
      $wasButtonDown = Test-ButtonDown

      $rect = Get-WindowRect ([int64]$handle)
      Write-Event ('open {0}' -f $name)
      Write-Trace (
        'guard attach name={0} hwnd={1} rect={2},{3}-{4},{5}' -f
          $name, [int64]$handle, $rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
    }
  }

  # Every few seconds: step aside if a newer guard for this display claimed the pid
  # file, exit if Zebar is gone, and give up after the lifetime cap so a stray
  # guard cannot linger forever (the bar starts a fresh one).
  #
  # Timed rather than counted in ticks, so the tick rate can change without
  # quietly turning this into a busy loop.
  if (($now - $lastHousekeeping).TotalMilliseconds -ge $HousekeepingMs) {
    $lastHousekeeping = $now

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

# window-ctl.ps1 -Action close|watch|guard -Match "<widget name>[,<name>...]"
#
# Widget windows of one pack can not reach each other through the client API, so
# this helper works on them from the outside. It finds top level windows that
# belong to zebar.exe and carry a widget name in their title. Zebar titles widget
# windows "Zebar - <pack id> / <widget name>", and matching on the widget name
# alone keeps working if that format ever changes.
#
#   close  Closes every match and prints how many it closed (0 if none).
#   watch  Waits for the matched window, then closes it as soon as it is
#          dismissed. Kept for one-off use and debugging.
#   guard  Long lived. Watches every name in one process and takes commands on
#          stdin, which is what the bar uses: starting a PowerShell per click is
#          what made opening and closing feel slow, so the bar starts one guard
#          at load and talks to it instead.
#
#          stdout protocol, one event per line:
#            open <name>        a panel window appeared
#            closed <name>      the guard closed it
#            gone <name>        it disappeared on its own
#            closed <name> <n>  reply to a "close" command, n = windows closed
#
#          stdin commands:
#            close <name>|all   close that panel now
#            quit               exit the guard
#
# A panel is dismissed by a mouse click outside it (left, right or middle), and by
# nothing else: focus changes and the pointer resting elsewhere both close popups
# that the user never asked to close.
# Closing happens here, with WM_CLOSE, so it never depends on the widget page
# being able to close itself. A trace file lives at %TEMP%\zebar-window-ctl.log.

param(
  [Parameter(Mandatory = $true)][ValidateSet('close', 'watch', 'guard')][string]$Action,
  [Parameter(Mandatory = $true)][string]$Match,
  [string]$Owner = 'default',
  [int]$TickMs = 100,
  [int]$ScanMs = 300,
  [int]$FindTimeoutMs = 8000,
  [int]$GraceMs = 250,
  [int]$MissesBeforeClose = 2,
  [int]$PointerDwellMs = 600,
  [int]$MaxLifetimeMinutes = 240
)

Add-Type -Namespace ZebarWin -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint message, System.IntPtr wParam, System.IntPtr lParam, uint flags, uint timeout, out System.IntPtr result);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint message, System.IntPtr wParam, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr hWnd, int index);
[DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr hWnd, int index, int value);
[DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(System.IntPtr hWnd, uint colorKey, byte alpha, uint flags);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr insertAfter, int x, int y, int width, int height, uint flags);
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

$WM_CLOSE = 0x0010
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$VK_ESCAPE = 0x1B
$SMTO_ABORTIFHUNG = 0x0002
$GWL_EXSTYLE = -20
$WS_EX_LAYERED = 0x00080000
$LWA_ALPHA = 0x00000002
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_NOZORDER = 0x0004
$SWP_NOACTIVATE = 0x0010
$logPath = Join-Path $env:TEMP 'zebar-window-ctl.log'

$matchNames = @($Match -split ',' |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -ne '' })

function Write-Trace([string]$message) {
  try {
    Add-Content -Path $logPath -Value (
      '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $message
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

    # Only titles that already match are checked against the process, so the
    # scan does not need to enumerate every process on the machine.
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

function Close-Window([int64]$handle) {
  $hwnd = [System.IntPtr]$handle

  # Two ways to get a closing animation, because the panel can only animate
  # itself if it hears us:
  #
  #   1. A proper Escape key down/up, which the panel's own handler listens for
  #      (repeat count and scan code set, or the key event is ignored).
  #   2. A fade of the window itself, done here, which cannot be missed.
  #
  # Then close the window, so nothing can stay stuck open.
  $scanEscape = 0x0001
  $keyDown = [System.IntPtr]([int64]$scanEscape -shl 16 -bor 1)
  $keyUp = [System.IntPtr]([int64]$scanEscape -shl 16 -bor 1 -bor 0xC0000000)
  [void][ZebarWin.Native]::PostMessage($hwnd, $WM_KEYDOWN, [System.IntPtr]$VK_ESCAPE, $keyDown)
  [void][ZebarWin.Native]::PostMessage($hwnd, $WM_KEYUP, [System.IntPtr]$VK_ESCAPE, $keyUp)

  try {
    $rect = New-Object ZebarWin.Native+RECT
    [void][ZebarWin.Native]::GetWindowRect($hwnd, [ref]$rect)

    $style = [ZebarWin.Native]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    if (($style -band $WS_EX_LAYERED) -eq 0) {
      [void][ZebarWin.Native]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -bor $WS_EX_LAYERED)
    }
    [void][ZebarWin.Native]::SetLayeredWindowAttributes($hwnd, 0, 255, $LWA_ALPHA)

    # About 120ms of fade, lifting a few pixels as it goes.
    foreach ($step in 1..6) {
      $alpha = [byte](255 - ($step * 42))
      [void][ZebarWin.Native]::SetLayeredWindowAttributes($hwnd, 0, $alpha, $LWA_ALPHA)
      [void][ZebarWin.Native]::SetWindowPos($hwnd, [System.IntPtr]::Zero, $rect.Left, ($rect.Top - $step), 0, 0,
        ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE))
      Start-Sleep -Milliseconds 20
    }
  } catch {
    # Fade is cosmetic: closing still has to happen.
  }

  $result = [System.IntPtr]::Zero
  [void][ZebarWin.Native]::SendMessageTimeout(
    $hwnd, $WM_CLOSE, [System.IntPtr]::Zero,
    [System.IntPtr]::Zero, $SMTO_ABORTIFHUNG, 2000, [ref]$result)
}

function Test-ClickedSinceLastCheck {
  # Bit 0x0001 means "pressed since the previous call", so a click that lands
  # between two polls is still caught.
  foreach ($virtualKey in 0x01, 0x02, 0x04) {
    if (([ZebarWin.Native]::GetAsyncKeyState($virtualKey) -band 0x0001) -ne 0) {
      return $true
    }
  }

  return $false
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

  while ($closed -lt 8) {
    $targets = Get-TargetWindows

    if ($targets.Count -eq 0) {
      break
    }

    foreach ($handle in $targets) {
      Close-Window ([int64]$handle)
      $closed++
    }

    Start-Sleep -Milliseconds 200
  }

  Write-Event $closed
  Write-Trace ('close match={0} closed={1}' -f $Match, $closed)
  exit 0
}

if ($Action -eq 'guard') {
  # One guard per bar. The bar passes an -Owner that identifies the display it
  # sits on, so two bars (one per monitor) do not retire each other, while a
  # reloaded bar takes over its own display's guard. A pid file beats asking WMI
  # for process command lines, which costs seconds.
  $ownerKey = ($Owner -replace '[^A-Za-z0-9._-]', '_')
  $pidFile = Join-Path $env:TEMP ('zebar-panel-guard-' + $ownerKey + '.pid')

  try {
    [System.IO.File]::WriteAllText($pidFile, [string]$PID)
  } catch {
    # Without the file the guard still works, it just cannot retire itself.
  }

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

    # Commands from the bar.
    if ($pendingRead.IsCompleted) {
      $line = ''

      try {
        $line = $pendingRead.Result
      } catch {
        $line = ''
      }

      if ($null -eq $line) {
        # stdin closed: the bar is gone.
        Write-Trace 'guard exit: stdin closed'
        break
      }

      $pendingRead = $stdin.ReadLineAsync()

      if ($line -ne '') {
        $parts = @($line.Trim() -split '\s+' | Where-Object { $_ -ne '' })

        if ($parts.Count -gt 0 -and $parts[0] -eq 'quit') {
          Write-Trace 'guard quit'
          break
        }

        if ($parts.Count -gt 1 -and $parts[0] -eq 'close') {
          $wanted = $parts[1]
          $closed = 0

          foreach ($entry in @($active)) {
            if ($wanted -eq 'all' -or $entry.Name -eq $wanted) {
              Close-Window $entry.Handle
              $recentlyClosed[[string]$entry.Handle] = Get-Date
              $closed++
              Write-Trace ('guard closed name={0} reason=command' -f $entry.Name)
            }
          }

          $active = @($active | Where-Object { $wanted -ne 'all' -and $_.Name -ne $wanted })
          Write-Event ('closed {0} {1}' -f $wanted, $closed)
        }
      }
    }

    # The cheap checks, every tick.
    $clicked = Test-ClickedSinceLastCheck
    $foreground = [ZebarWin.Native]::GetForegroundWindow().ToInt64()
    $now = Get-Date

    if ($clicked -or $active.Count -gt 0) {
      foreach ($entry in @($active)) {
        if (-not [ZebarWin.Native]::IsWindow([System.IntPtr]$entry.Handle)) {
          Write-Event ('gone {0}' -f $entry.Name)
          Write-Trace ('guard detach name={0} reason=window-gone' -f $entry.Name)
          $active = @($active | Where-Object { $_ -ne $entry })
          continue
        }

        $isFocused = ($foreground -eq $entry.Handle)

        if ($isFocused) {
          $entry.EverFocused = $true
        }

        if (($now - $entry.AttachedAt).TotalMilliseconds -lt $GraceMs) {
          continue
        }

        $reason = $null

        if ($clicked -and -not (Test-PointerInsideWindow $entry.Handle)) {
          $reason = 'click-outside'
        }

        # Click outside is the only dismissal, deliberately. Focus based rules
        # close a popup on its own: Windows hands the focus to the new window and
        # takes it away again for reasons the user never sees, and the panel
        # vanishes right after opening. The pointer resting elsewhere is not a
        # dismissal either.

        if ($reason) {
          Close-Window $entry.Handle
          $recentlyClosed[[string]$entry.Handle] = $now
          Write-Event ('closed {0}' -f $entry.Name)
          Write-Trace ('guard closed name={0} reason={1}' -f $entry.Name, $reason)
          $active = @($active | Where-Object { $_ -ne $entry })
        }
      }
    }

    # Attach to new panels, at a slower cadence: enumerating windows is the
    # expensive part.
    if (($now - $lastScan).TotalMilliseconds -ge $ScanMs) {
      $lastScan = $now

      # Forget closures older than a few seconds.
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
        $active += [PSCustomObject]@{
          Name         = $name
          Handle       = [int64]$handle
          AttachedAt   = $now
          Misses       = 0
          EverFocused  = $false
          OutsideSince = $null
        }
        [void](Test-ClickedSinceLastCheck) # swallow the click that opened it
        Write-Event ('open {0}' -f $name)
        Write-Trace ('guard attach name={0}' -f $name)
      }
    }

    # Every ~5 seconds: step aside if a newer guard for this display claimed the
    # pid file, exit if Zebar is gone, and give up after the lifetime cap so a
    # stray guard cannot linger forever (a click starts a fresh one).
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
}

# -Action watch
$loopStarted = Get-Date
$handle = $null
$attachedAt = $null
$misses = 0
$outsideSince = $null
$everFocused = $false
$reason = $null

while ($true) {
  $targets = Get-TargetWindows

  if ($targets.Count -eq 0) {
    if ($null -eq $handle) {
      if (((Get-Date) - $loopStarted).TotalMilliseconds -gt $FindTimeoutMs) {
        $reason = 'never-appeared'
        break
      }
    } else {
      if (((Get-Date) - $attachedAt).TotalMilliseconds -gt $FindTimeoutMs) {
        $reason = 'target-gone'
        break
      }

      $handle = $null
      $misses = 0
      $outsideSince = $null
    }

    Start-Sleep -Milliseconds $TickMs
    continue
  }

  if ($null -eq $handle) {
    $handle = [int64]$targets[0]
    $attachedAt = Get-Date
    $everFocused = $false
    [void](Test-ClickedSinceLastCheck)
    Write-Trace ('watch start match={0}' -f $Match)
  }

  $isFocused = ([ZebarWin.Native]::GetForegroundWindow().ToInt64() -eq $handle)

  if ($isFocused) {
    $everFocused = $true
  }

  if (((Get-Date) - $attachedAt).TotalMilliseconds -lt $GraceMs) {
    Start-Sleep -Milliseconds $TickMs
    continue
  }

  if ((Test-ClickedSinceLastCheck) -and -not (Test-PointerInsideWindow $handle)) {
    $reason = 'click-outside'
    break
  }

  if ($isFocused) {
    $misses = 0
    $outsideSince = $null
  } elseif ($everFocused) {
    $misses++

    if ($misses -ge $MissesBeforeClose) {
      $reason = 'lost-foreground'
      break
    }
  } else {
    if (Test-PointerInsideWindow $handle) {
      $outsideSince = $null
    } elseif ($null -eq $outsideSince) {
      $outsideSince = Get-Date
    } elseif (((Get-Date) - $outsideSince).TotalMilliseconds -ge $PointerDwellMs) {
      $reason = 'pointer-left'
      break
    }
  }

  Start-Sleep -Milliseconds $TickMs
}

if ($reason -ne 'target-gone' -and $reason -ne 'never-appeared' -and $null -ne $handle) {
  Close-Window $handle
  Write-Event 'close'
}

Write-Trace ('watch end match={0} reason={1} focused-once={2}' -f $Match, $reason, $everFocused)

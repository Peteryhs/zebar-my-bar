# window-ctl.ps1 -Action close|guard -Match "<widget name>[,<name>...]"
#
# Widget windows of one pack cannot reach each other through the client API, so
# this helper works on them from the outside. It finds top level windows that
# belong to zebar.exe and carry a widget name in their title. Zebar titles widget
# windows "Zebar - <pack id> / <widget name>", and matching on the widget name
# alone keeps working if that format ever changes.
#
#   close  Closes every match and prints how many it closed (0 if none).
#   guard  Long lived. One process per bar, doing everything the bar cannot do for
#          itself. Reports on stdout, one event per line:
#
#            open <name>      a panel window appeared
#            closed <name>    the guard closed it
#            gone <name>      it disappeared on its own
#            fg max|float     whether the foreground window is maximized
#            app <name>       the foreground application, for the bar to show
#
# A panel is dismissed by a mouse click outside it, and by nothing else. Focus
# changes and the pointer resting elsewhere both close popups the user never asked
# to close: Windows hands focus to a new window and takes it away again for
# reasons that are invisible from here, and a panel that vanishes a second after
# opening is the result.
#
# Clicks are detected here rather than in the panel's page. It does not depend on
# which window has the focus, or on a page receiving an event, both of which turned
# out to be unreliable. They arrive through a low level mouse hook, so the guard is
# woken by a click rather than looking for one: polling the mouse state at 50Hz
# worked, but a laptop should not be woken fifty times a second to be told nothing
# happened.
#
# Closing happens here too, with WM_CLOSE after fading the window, so it never
# depends on the page being able to close itself.
#
# The foreground state and application name used to be a second PowerShell
# (fg-state.ps1). They are here now: it is the same polling loop, and one helper
# process for a bar is enough.
#
# A trace file lives at %TEMP%\zebar-window-ctl.log.

param(
  [Parameter(Mandatory = $true)][ValidateSet('close', 'guard')][string]$Action,
  [Parameter(Mandatory = $true)][string]$Match,
  [string]$Owner = 'default',
  # How often the mouse buttons are read. A click is held for something like 50 to
  # 150ms, so this has to be well inside that.
  [int]$PollMs = 20,
  # How long a pass waits for a click before going round anyway to check on the
  # panel and the foreground window. A click cuts it short.
  [int]$WaitMs = 250,
  # Looking for new panel windows: the expensive part, so it runs at this rate only
  # when a panel is open or one was just asked for, and at the lazy rate otherwise.
  [int]$ScanMs = 400,
  [int]$ScanIdleMs = 3000,
  [int]$ScanAfterClickMs = 2500,
  [int]$GraceMs = 250,
  [int]$ForegroundMs = 250,
  [int]$HousekeepingMs = 5000,
  [int]$MaxLifetimeMinutes = 240
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ZebarWin {
  public static class Native {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int maxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    public struct POINT { public int X; public int Y; }
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    /*
     * Clicks, from the button's own state, with the press edge worked out here.
     *
     * Not the low bit of GetAsyncKeyState, which means "pressed since the previous
     * call" and is cleared by whichever caller reads it next: any other process
     * polling input consumes the press first, so clicks went missing at random.
     * The high bit is the button's actual state and nothing else can take it away.
     *
     * Not a low level mouse hook either, which was tried. A hook is woken by a
     * click instead of looking for one, which sounds strictly better, but WH_MOUSE_LL
     * receives every mouse move as well, each one a transition out of native code
     * into managed. Measured, it cost more while the mouse was in use than polling
     * costs all the time, and it puts this code in the path of every mouse event on
     * the machine. The guard only needs clicks while a panel is open, so it polls
     * quickly then and not at all otherwise.
     */
    private static bool wasDown = false;

    public static bool AnyButtonDown() {
      return (GetAsyncKeyState(0x01) & 0x8000) != 0
          || (GetAsyncKeyState(0x02) & 0x8000) != 0
          || (GetAsyncKeyState(0x04) & 0x8000) != 0;
    }

    public static void ResyncButtons() { wasDown = AnyButtonDown(); }

    public static bool PolledPress() {
      bool down = AnyButtonDown();
      bool pressed = down && !wasDown;
      wasDown = down;
      return pressed;
    }

    /*
     * Waits for a press, returning as soon as there is one, or when the time is up.
     *
     * The point of doing the waiting here is that the loop around it is PowerShell,
     * and a pass of it costs the better part of a millisecond however little it does.
     * Reading the buttons every 20ms from up there cost about two percent of a core;
     * reading them here and waking the loop four times a second costs a fraction of
     * that, and the click is still noticed within 20ms.
     */
    public static bool WaitForPress(int timeoutMs, int stepMs) {
      int waited = 0;

      while (true) {
        if (PolledPress()) return true;
        if (waited >= timeoutMs) return false;

        Thread.Sleep(stepMs);
        waited += stepMs;
      }
    }

    /*
     * Finding the panel windows.
     *
     * Enumerating top level windows means a callback per window, and there are a
     * couple of hundred of them. Done from PowerShell that was a couple of hundred
     * transitions out of native code and into the interpreter, several times a
     * second, and it was the single most expensive thing the guard did. Here it is
     * one call in, one array out.
     */
    private static List<long> matchedWindows;
    private static string[] wantedNames;
    private static string wantedProcess;

    public static long[] FindWindows(string[] names, string processName) {
      matchedWindows = new List<long>();
      wantedNames = names;
      wantedProcess = processName;

      EnumWindows(new EnumWindowsProc(OnWindow), IntPtr.Zero);

      return matchedWindows.ToArray();
    }

    private static bool OnWindow(IntPtr hWnd, IntPtr lParam) {
      if (!IsWindowVisible(hWnd)) return true;

      StringBuilder title = new StringBuilder(512);
      GetWindowTextW(hWnd, title, 512);
      string text = title.ToString();

      if (text.Length == 0) return true;
      if (IndexOfName(text, wantedNames) < 0) return true;

      // Only titles that already match are checked against the process, so this
      // does not need to look up every process on the machine.
      uint owner;
      GetWindowThreadProcessId(hWnd, out owner);

      try {
        System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById((int)owner);

        if (string.Equals(process.ProcessName, wantedProcess, StringComparison.OrdinalIgnoreCase)) {
          matchedWindows.Add(hWnd.ToInt64());
        }
      } catch {
        // Gone between the enumeration and the lookup.
      }

      return true;
    }

    private static int IndexOfName(string title, string[] names) {
      for (int i = 0; i < names.Length; i++) {
        if (title.IndexOf(names[i], StringComparison.OrdinalIgnoreCase) >= 0) return i;
      }

      return -1;
    }

    public static string NameForWindow(long handle, string[] names) {
      StringBuilder title = new StringBuilder(512);
      GetWindowTextW(new IntPtr(handle), title, 512);

      int index = IndexOfName(title.ToString(), names);

      return index < 0 ? "unknown" : names[index];
    }
    /*
     * What has the foreground: whether it is maximized, and what to call it.
     *
     * Returns "max<tab>Name", "float<tab>Name", or an empty string meaning one of
     * our own windows has it, which is not an answer to "what is the user working
     * in" and should leave the bar as it is.
     *
     * All of it in one call, with the answer cached per process, because this runs
     * several times a second and every part of it was expensive from PowerShell:
     * Get-Process is a cmdlet invocation, and reading MainModule.FileVersionInfo to
     * get "Visual Studio Code" rather than "Code" is dearer still. Up there it cost
     * the guard nearly two percent of a core while it sat doing nothing.
     */
    private static readonly string[] shellClasses = new string[] {
      "Progman", "WorkerW", "SysListView32", "Shell_TrayWnd", "Shell_SecondaryTrayWnd",
      "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow"
    };

    private static Dictionary<uint, string> appNames = new Dictionary<uint, string>();

    // Process ids are reused, so remembered names eventually describe the wrong
    // process. The caller forgets them occasionally.
    public static void ForgetAppNames() { appNames.Clear(); }

    public static string ForegroundReport(string ownProcess) {
      IntPtr window = GetForegroundWindow();

      if (window == IntPtr.Zero) return "float\t";

      uint owner;
      GetWindowThreadProcessId(window, out owner);

      // Cached as "processName<tab>displayName", so a window we have seen before
      // costs nothing: no process lookup, no version info read.
      string cached;

      if (!appNames.TryGetValue(owner, out cached)) {
        string processName = "";
        string appName = "";

        try {
          System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById((int)owner);
          processName = process.ProcessName;
          appName = processName;

          try {
            string described = process.MainModule.FileVersionInfo.FileDescription;

            if (described != null && described.Trim().Length > 0) appName = described.Trim();
          } catch {
            // Protected process: the process name will do.
          }
        } catch {
          // Gone already.
        }

        cached = processName + "\t" + appName;
        appNames[owner] = cached;
      }

      int tab = cached.IndexOf('\t');
      string ownerName = cached.Substring(0, tab);
      string displayName = cached.Substring(tab + 1);

      if (string.Equals(ownerName, ownProcess, StringComparison.OrdinalIgnoreCase)) {
        return "";
      }

      StringBuilder className = new StringBuilder(256);
      GetClassName(window, className, 256);
      string cls = className.ToString();

      for (int i = 0; i < shellClasses.Length; i++) {
        // A shell surface with the focus means the bare desktop, as far as the bar
        // is concerned.
        if (cls == shellClasses[i]) return "float\t";
      }

      if (!IsWindowVisible(window)) return "float\t";

      return (IsZoomed(window) ? "max" : "float") + "\t" + displayName;
    }
  }
}
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
  return [ZebarWin.Native]::FindWindows($matchNames, 'zebar')
}

function Get-WindowName([int64]$handle) {
  return [ZebarWin.Native]::NameForWindow($handle, $matchNames)
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

# Fade the window out, then close it. The fade is done here, on the window, rather
# than by asking the page to animate: a panel that is being dismissed may not be
# in a position to run anything, and a window that simply vanishes looks broken.
function Close-Window([int64]$handle) {
  $hwnd = [System.IntPtr]$handle

  try {
    $rect = Get-WindowRect $handle
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
  # discovering that.
  Start-Sleep -Milliseconds 120
  $survived = [ZebarWin.Native]::IsWindow($hwnd)

  if ($survived) {
    Write-Trace ('  WM_CLOSE ignored, window {0} still alive' -f $handle)
  }

  return (-not $survived)
}

if ($Action -eq 'close') {
  $closed = 0

  foreach ($handle in (Get-TargetWindows)) {
    [void](Close-Window ([int64]$handle))
    $closed++
  }

  Write-Event $closed
  Write-Trace ('close match={0} closed={1}' -f $Match, $closed)
  exit 0
}

# ---------------------------------------------------------------------------
# -Action guard
# ---------------------------------------------------------------------------

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

[ZebarWin.Native]::ResyncButtons()

Write-Trace ('guard start names={0} pid={1} owner={2}' -f ($matchNames -join '|'), $PID, $ownerKey)

# stdin is read only to notice the bar going away: when the bar's page is gone the
# pipe closes and the read returns null.
#
# The bar does not send commands here. It used to, and they never arrived: zebar's
# shellWrite resolves without delivering anything, so the write looked fine from
# the page while this process saw nothing.
$stdin = New-Object System.IO.StreamReader ([Console]::OpenStandardInput())
$pendingRead = $stdin.ReadLineAsync()

$active = @()
# A closed window can linger for a moment, so remember what we just closed to
# avoid attaching to it again on the next scan.
$recentlyClosed = @{}
$lastScan = (Get-Date).AddYears(-1)
$lastClickAt = (Get-Date).AddYears(-1)
$lastForeground = (Get-Date).AddYears(-1)
$lastHousekeeping = Get-Date
$lastCacheClear = Get-Date
$lifeDeadline = (Get-Date).AddMinutes($MaxLifetimeMinutes)

# --- foreground window reporting (was fg-state.ps1) ------------------------
#
# Worked out in the compiled class, in one call, and reported only when it changes.
$lastFgState = ''
$lastAppName = ''
# ---------------------------------------------------------------------------

while ($true) {
  # Waits inside the compiled class, which returns the moment a button goes down.
  # So the loop is woken by a click, or four times a second to do its housekeeping.
  $clicked = [ZebarWin.Native]::WaitForPress($WaitMs, $PollMs)

  $now = Get-Date

  if ($clicked) { $lastClickAt = $now }

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

  # Every click is written down, whatever is decided about it, along with what the
  # decision was made from. A click that is detected and deliberately dropped and a
  # click that was never detected at all look identical from the far side of the
  # screen, and telling those apart is the whole difficulty.
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

  <#
    Look for new panels.

    Enumerating top level windows is the most expensive thing here even with the
    enumeration itself compiled, because Windows calls back once per window and
    there are a couple of hundred of them. A panel can only appear because something
    was clicked, so this runs at the brisk rate while a panel is open or a click has
    just happened, and rarely otherwise. A panel opened from a command line is
    picked up on the lazy cadence, which is the only thing the laziness costs.
  #>
  $scanEvery = if ($active.Count -gt 0 -or
                   ($now - $lastClickAt).TotalMilliseconds -lt $ScanAfterClickMs) {
    $ScanMs
  } else {
    $ScanIdleMs
  }

  if (($now - $lastScan).TotalMilliseconds -ge $scanEvery) {
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

      # Discard the click that opened the panel; the grace period covers the rest.
      [ZebarWin.Native]::ResyncButtons()

      $rect = Get-WindowRect ([int64]$handle)
      Write-Event ('open {0}' -f $name)
      Write-Trace (
        'guard attach name={0} hwnd={1} rect={2},{3}-{4},{5}' -f
          $name, [int64]$handle, $rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
    }
  }

  # Foreground window: whether it is maximized, and which application it is.
  if (($now - $lastForeground).TotalMilliseconds -ge $ForegroundMs) {
    $lastForeground = $now
    $report = [ZebarWin.Native]::ForegroundReport('zebar')

    # Empty means one of our own windows has the focus: say nothing, change nothing.
    if ($report -ne '') {
      $parts = $report -split "`t", 2

      if ($parts[0] -ne $lastFgState) {
        $lastFgState = $parts[0]
        Write-Event ('fg {0}' -f $parts[0])
      }

      if ($parts[1] -ne $lastAppName) {
        $lastAppName = $parts[1]
        Write-Event ('app {0}' -f $parts[1])
      }
    }
  }

  # Every few seconds: step aside if a newer guard for this display claimed the pid
  # file, exit if Zebar is gone, and give up after the lifetime cap so a stray
  # guard cannot linger forever (the bar starts a fresh one).
  if (($now - $lastHousekeeping).TotalMilliseconds -ge $HousekeepingMs) {
    $lastHousekeeping = $now

    # Cleared rarely rather than every few seconds: resolving a name reads the
    # executable's version info, and being briefly wrong about a label after a
    # process id is reused costs nothing.
    if (($now - $lastCacheClear).TotalMinutes -ge 5) {
      $lastCacheClear = $now
      [ZebarWin.Native]::ForgetAppNames()
    }

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
}

exit 0

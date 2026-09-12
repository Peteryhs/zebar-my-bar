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
  # How long a loop pass waits for a click before going round anyway. A click cuts
  # the wait short, so this is the idle wake interval, not the click latency.
  [int]$IdleWaitMs = 250,
  # Fallback tick, used only if the mouse hook could not be installed.
  [int]$PollMs = 20,
  # Panels appear as a result of a click, so the window scan runs at this cadence
  # for a moment after one and lazily the rest of the time.
  [int]$ScanBusyMs = 300,
  [int]$ScanIdleMs = 2000,
  [int]$ScanBusyForMs = 2500,
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
    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

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
    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG message, IntPtr hWnd, uint filterMin, uint filterMax);

    public struct POINT { public int X; public int Y; }
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
      public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
      public uint time; public POINT pt;
    }

    /*
     * Mouse presses, counted as they happen.
     *
     * A low level mouse hook needs a message loop on the thread that installed it,
     * so one runs on a background thread here. The callback does nothing but count,
     * which matters: Windows quietly drops a hook whose callback is slow.
     *
     * The alternative was polling GetAsyncKeyState, which is what this replaces. It
     * cost a wake every 20ms for the life of the bar, and reading its "pressed
     * since last call" bit was worse than useless because any other process
     * polling input consumed the press first.
     */
    private const int WH_MOUSE_LL = 14;
    private static int pressCount = 0;
    private static IntPtr hookHandle = IntPtr.Zero;
    private static HookProc hookCallback;   // held so it is not collected
    private static Thread hookThread;
    private static ManualResetEventSlim pressSignal = new ManualResetEventSlim(false);

    public static bool StartClickHook() {
      hookThread = new Thread(new ThreadStart(HookLoop));
      hookThread.IsBackground = true;
      hookThread.Start();

      // The hook is installed on that thread; give it a moment to report back.
      for (int i = 0; i < 40 && hookHandle == IntPtr.Zero; i++) Thread.Sleep(25);

      return hookHandle != IntPtr.Zero;
    }

    private static void HookLoop() {
      hookCallback = new HookProc(OnMouseEvent);
      hookHandle = SetWindowsHookEx(WH_MOUSE_LL, hookCallback, IntPtr.Zero, 0);

      if (hookHandle == IntPtr.Zero) return;

      MSG message;
      while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) { }
    }

    private static IntPtr OnMouseEvent(int code, IntPtr wParam, IntPtr lParam) {
      if (code >= 0) {
        int what = wParam.ToInt32();

        // Left, right and middle button down. Not up, and not movement.
        if (what == 0x0201 || what == 0x0204 || what == 0x0207) {
          Interlocked.Increment(ref pressCount);
          pressSignal.Set();
        }
      }

      return CallNextHookEx(hookHandle, code, wParam, lParam);
    }

    // How many presses since this was last asked, and resets the count.
    public static int TakePresses() {
      pressSignal.Reset();

      return Interlocked.Exchange(ref pressCount, 0);
    }

    /*
     * Waits for a press, up to a limit, blocking on an event the hook sets rather
     * than looking repeatedly. A click wakes this immediately and idling costs one
     * wake per timeout, which is the point: the first version of this slept in a
     * loop and was no better than the polling it replaced.
     */
    public static int WaitForPress(int timeoutMs) {
      if (pressSignal.Wait(timeoutMs)) pressSignal.Reset();

      return Interlocked.Exchange(ref pressCount, 0);
    }

    // Fallback for when the hook could not be installed: the button's own state,
    // which nothing else can clear, with the press edge worked out here.
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

$hooked = [ZebarWin.Native]::StartClickHook()

if (-not $hooked) {
  [ZebarWin.Native]::ResyncButtons()
}

Write-Trace (
  'guard start names={0} pid={1} owner={2} clicks={3}' -f
    ($matchNames -join '|'), $PID, $ownerKey,
    $(if ($hooked) { 'hook' } else { 'polled' }))

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

# Shell surfaces are not "windows" for our purpose: if one of these has focus, the
# bar floats like it does on the bare desktop.
$shellClasses = @(
  'Progman', 'WorkerW', 'SysListView32', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd',
  'Windows.UI.Core.CoreWindow', 'XamlExplorerHostIslandWindow'
)

# Zebar's own windows are not an answer to "what is the user working in". The bar
# and every panel take the foreground when clicked, and since neither is maximized
# the state would flip to "float" the moment the bar was touched.
#
# A widget's top level window belongs to zebar.exe, which the panel scan above
# relies on to find panels at all, so the process name is enough. This used to walk
# the parent chain with a WMI query per hop, on the belief that the window belonged
# to a WebView2 child; that cost most of the guard's idle CPU, for an answer it
# could read directly.
$appNameCache = @{}

function Test-OwnProcess([uint32]$processId) {
  if ($processId -eq 0) { return $false }

  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue

  return ($process -and $process.ProcessName -eq 'zebar')
}

# The application's name as a person would say it: "Visual Studio Code", not
# "Code.exe", and not the window title, which is usually the document and changes
# on every keystroke.
function Get-AppName([uint32]$processId) {
  if ($processId -eq 0) { return '' }
  if ($appNameCache.ContainsKey($processId)) { return $appNameCache[$processId] }

  $name = ''

  try {
    $process = Get-Process -Id $processId -ErrorAction Stop
    $name = $process.ProcessName

    try {
      $described = $process.MainModule.FileVersionInfo.FileDescription

      if ($described -and $described.Trim() -ne '') { $name = $described.Trim() }
    } catch {
      # Protected process: the process name will do.
    }
  } catch {
    $name = ''
  }

  $appNameCache[$processId] = $name

  return $name
}

$lastFgState = ''
$lastAppName = ''

function Update-Foreground {
  $handle = [ZebarWin.Native]::GetForegroundWindow()

  if ($handle -eq [System.IntPtr]::Zero) {
    return @{ State = 'float'; App = '' }
  }

  $ownerPid = [uint32]0
  [void][ZebarWin.Native]::GetWindowThreadProcessId($handle, [ref]$ownerPid)

  # One of ours: report nothing and leave the bar as it is.
  if (Test-OwnProcess $ownerPid) {
    return $null
  }

  $classBuffer = New-Object System.Text.StringBuilder 256
  [void][ZebarWin.Native]::GetClassName($handle, $classBuffer, 256)
  $className = $classBuffer.ToString()

  if (($shellClasses -contains $className) -or
      -not [ZebarWin.Native]::IsWindowVisible($handle)) {
    return @{ State = 'float'; App = '' }
  }

  $state = 'float'
  if ([ZebarWin.Native]::IsZoomed($handle)) { $state = 'max' }

  return @{ State = $state; App = (Get-AppName $ownerPid) }
}

# ---------------------------------------------------------------------------

while ($true) {
  # Wait for a click. The wait is cut short the moment one arrives, so this is the
  # idle wake interval rather than the click latency.
  $clicked = $false

  if ($hooked) {
    $clicked = ([ZebarWin.Native]::WaitForPress($IdleWaitMs) -gt 0)
  } else {
    $clicked = [ZebarWin.Native]::PolledPress()
    if (-not $clicked) { Start-Sleep -Milliseconds $PollMs }
  }

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

  # Look for new panels. A panel can only appear because something was clicked, so
  # this runs briskly for a moment after a click and lazily the rest of the time. A
  # panel opened from a command line is picked up on the slow cadence instead, which
  # is the only thing the laziness costs.
  $scanEvery = if (($now - $lastClickAt).TotalMilliseconds -lt $ScanBusyForMs) {
    $ScanBusyMs
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

      # Discard the click that opened the panel: with the hook it is already
      # counted, and the grace period covers the rest.
      [void][ZebarWin.Native]::TakePresses()
      if (-not $hooked) { [ZebarWin.Native]::ResyncButtons() }

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
    $foreground = Update-Foreground

    if ($null -ne $foreground) {
      if ($foreground.State -ne $lastFgState) {
        $lastFgState = $foreground.State
        Write-Event ('fg {0}' -f $foreground.State)
      }

      if ($foreground.App -ne $lastAppName) {
        $lastAppName = $foreground.App
        Write-Event ('app {0}' -f $foreground.App)
      }
    }
  }

  # Every few seconds: step aside if a newer guard for this display claimed the pid
  # file, exit if Zebar is gone, and give up after the lifetime cap so a stray
  # guard cannot linger forever (the bar starts a fresh one).
  if (($now - $lastHousekeeping).TotalMilliseconds -ge $HousekeepingMs) {
    $lastHousekeeping = $now

    # Process ids are reused, so remembered application names eventually describe
    # the wrong process. Cleared rarely rather than every few seconds: resolving a
    # name reads the executable's version info, and the cost of being briefly wrong
    # about a label is small.
    if ($appNameCache.Count -gt 0 -and ($now - $lastCacheClear).TotalMinutes -ge 5) {
      $lastCacheClear = $now
      $appNameCache.Clear()
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

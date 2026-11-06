using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ZebarDock {
  // Use Zebar's own HWND: a second appbar would reserve the strip twice and
  // leave cleanup dependent on the lifetime of a PowerShell helper.
  public static class Guard {
    private static readonly Dictionary<long, long> invalidSince = new Dictionary<long, long>();
    private sealed class DisplayObservation {
      public RECT Monitor;
      public int Height;
      public long Since;
    }
    private static readonly Dictionary<long, DisplayObservation> displays = new Dictionary<long, DisplayObservation>();
    internal const double InitializationGraceMs = 20000;
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO {
      public int cbSize;
      public RECT Monitor, Work;
      public uint Flags;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct APPBARDATA {
      public uint cbSize;
      public IntPtr hWnd;
      public uint Callback, Edge;
      public RECT Rect;
      public IntPtr Param;
    }
    public sealed class State {
      public long Handle;
      public RECT Bounds, Monitor, Work;
      public int ExpectedHeight;
      public bool TopMost, Reserved, GeometryValid;
      public string Repair = "";
    }
    // A narrow native boundary lets regression tests exercise the actual repair
    // sequence without changing the desktop or requiring Zebar to be running.
    internal interface IAppBarApi {
      uint RegisterCallback();
      UIntPtr Message(uint message, ref APPBARDATA data);
      bool Position(IntPtr window, IntPtr after, RECT rect, uint flags);
    }
    private sealed class AppBarApi : IAppBarApi {
      public uint RegisterCallback() { return RegisterWindowMessageW("my-bar.appbar-recovery"); }
      public UIntPtr Message(uint message, ref APPBARDATA data) { return SHAppBarMessage(message, ref data); }
      public bool Position(IntPtr window, IntPtr after, RECT rect, uint flags) {
        return SetWindowPos(window, after, rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top, flags);
      }
    }
    private delegate bool EnumProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("shell32.dll")] private static extern UIntPtr SHAppBarMessage(uint message, ref APPBARDATA data);

    // All native rectangles must be physical pixels, including on mixed-DPI
    // displays. Restore the caller's context so the panel helper is unaffected.
    public static State[] Check(string exactTitle, bool repair) {
      return Check(exactTitle, repair, 42);
    }

    public static State[] Check(string exactTitle, bool repair, int logicalHeight) {
      if (logicalHeight < 16 || logicalHeight > 128) throw new ArgumentOutOfRangeException("logicalHeight");
      if (!repair) return CheckCore(exactTitle, false, logicalHeight);
      // Each monitor already has a panel helper. Serialize their docking checks
      // across processes so two helpers cannot negotiate the same HWND at once.
      using (Mutex gate = new Mutex(false, @"Local\my-bar-dock-recovery")) {
        bool entered;
        try { entered = gate.WaitOne(0); }
        catch (AbandonedMutexException) { entered = true; }
        if (!entered) return new State[0];
        try { return CheckCore(exactTitle, true, logicalHeight); }
        finally { gate.ReleaseMutex(); }
      }
    }

    private static State[] CheckCore(string exactTitle, bool repair, int logicalHeight) {
      IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
      if (previous == IntPtr.Zero) throw new InvalidOperationException("Cannot obtain physical DPI coordinates for docking.");
      try {
        List<State> states = new List<State>();
        HashSet<long> visibleBars = new HashSet<long>();
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
          if (!IsWindowVisible(window)) return true;
          StringBuilder title = new StringBuilder(512);
          GetWindowTextW(window, title, title.Capacity);
          if (!string.Equals(title.ToString(), exactTitle, StringComparison.Ordinal)) return true;
          uint pid;
          GetWindowThreadProcessId(window, out pid);
          try {
            using (Process process = Process.GetProcessById((int)pid)) {
              if (!string.Equals(process.ProcessName, "zebar", StringComparison.OrdinalIgnoreCase)) return true;
            }
          } catch (ArgumentException) { return true; }

          State state = Read(window, logicalHeight);
          if (state == null) return true;
          visibleBars.Add(state.Handle);
          if (repair) {
            // Zebar creates a visible default-size WebView before applying its
            // preset and registering the appbar. Do not race that initialization
            // or a brief display/DPI transition. Persistent bad sizes are fixed
            // on the following guard pass, always using the configured height.
            long since;
            long now = Stopwatch.GetTimestamp();
            double displayAge = ObserveDisplay(state, now);
            // A window can already have its final size while Zebar is still
            // awaiting display enumeration and ABM_NEW. Registering its HWND
            // here makes Zebar's later registration fail and creates a loop.
            if ((!state.Reserved || !state.TopMost) && displayAge < InitializationGraceMs) {
              state.Repair = "waiting for Zebar display initialization";
              states.Add(state);
              return true;
            }
            if (!state.GeometryValid) {
              if (!invalidSince.TryGetValue(state.Handle, out since)) {
                since = now;
                invalidSince[state.Handle] = since;
              }
              if (!ReadyForRepair(state, (now - since) * 1000.0 / Stopwatch.Frequency)) {
                state.Repair = "waiting for bar geometry to settle";
                states.Add(state);
                return true;
              }
            } else invalidSince.Remove(state.Handle);
            List<string> actions = RepairWindow(new AppBarApi(), window, state);
            State updated = Read(window, logicalHeight);
            if (updated != null) state = updated;
            if (state.GeometryValid) invalidSince.Remove(state.Handle);
            if (!state.Reserved || !state.TopMost) actions.Add("protection still unhealthy; retry pending");
            state.Repair = string.Join("; ", actions.ToArray());
          }
          states.Add(state);
          return true;
        }, IntPtr.Zero);
        if (repair) {
          foreach (long handle in new List<long>(displays.Keys)) {
            if (!visibleBars.Contains(handle)) displays.Remove(handle);
          }
          foreach (long handle in new List<long>(invalidSince.Keys)) {
            if (!visibleBars.Contains(handle)) invalidSince.Remove(handle);
          }
        }
        return states.ToArray();
      } finally {
        if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
      }
    }

    internal static double ObserveDisplay(State state, long now) {
      DisplayObservation observation;
      RECT monitor = state.Monitor;
      if (!displays.TryGetValue(state.Handle, out observation) ||
          observation.Monitor.Left != monitor.Left || observation.Monitor.Top != monitor.Top ||
          observation.Monitor.Right != monitor.Right || observation.Monitor.Bottom != monitor.Bottom ||
          observation.Height != state.ExpectedHeight) {
        observation = new DisplayObservation { Monitor = monitor, Height = state.ExpectedHeight, Since = now };
        displays[state.Handle] = observation;
        invalidSince.Remove(state.Handle);
      }
      return (now - observation.Since) * 1000.0 / Stopwatch.Frequency;
    }

    internal static bool ReadyForRepair(State state, double invalidMilliseconds) {
      return state.GeometryValid || invalidMilliseconds >= 1000;
    }

    internal static bool SafeReservation(RECT monitor, RECT rect, int height) {
      // This pack owns exactly one full-width strip at the monitor's top edge.
      // A shifted query must never be turned into a growing stack of appbars.
      return height > 0 && rect.Top == monitor.Top &&
        rect.Bottom == monitor.Top + height && rect.Bottom < monitor.Bottom &&
        rect.Left >= monitor.Left && rect.Right <= monitor.Right && rect.Right > rect.Left;
    }

    internal static State Describe(long handle, RECT bounds, RECT monitor, RECT work, bool topMost, uint dpi, int logicalHeight) {
      // Match Zebar's to_px_scaled: positive pixel lengths are truncated, not
      // rounded (42px at 125% is 52 physical pixels).
      if (dpi < 96 || dpi > 768) throw new InvalidOperationException("Invalid bar DPI; skipping docking repair.");
      int height = (int)(logicalHeight * (dpi / 96.0));
      bool geometry = SafeReservation(monitor, bounds, height) && bounds.Left == work.Left && bounds.Right == work.Right;
      return new State {
        Handle = handle, Bounds = bounds, Monitor = monitor, Work = work,
        ExpectedHeight = height, GeometryValid = geometry, TopMost = topMost,
        // A deeper work area is not proof that this bar's reservation is sound.
        Reserved = geometry && work.Top == monitor.Top + height
      };
    }

    internal static List<string> RepairWindow(IAppBarApi api, IntPtr window, State state) {
      List<string> actions = new List<string>();
      if (!state.TopMost) {
        actions.Add(api.Position(window, new IntPtr(-1), new RECT(), 0x13)
          ? "topmost restored" : "topmost repair failed"); // NOSIZE | NOMOVE | NOACTIVATE
      }
      if (state.Reserved && state.GeometryValid) return actions;

      RECT desired = state.Monitor;
      desired.Bottom = desired.Top + state.ExpectedHeight;
      if (!SafeReservation(state.Monitor, desired, state.ExpectedHeight)) {
        actions.Add("monitor cannot fit configured bar; docking skipped");
        return actions;
      }

      APPBARDATA data = new APPBARDATA();
      data.cbSize = (uint)Marshal.SizeOf(typeof(APPBARDATA));
      data.hWnd = window;
      data.Edge = 1; // ABE_TOP
      data.Callback = api.RegisterCallback();
      if (data.Callback == 0) {
        actions.Add("callback registration failed; docking skipped");
        return actions;
      }

      // Remove only our HWND's previous reservation before negotiating. This
      // clears an inflated reservation and avoids including it in a new query.
      api.Message(1, ref data); // ABM_REMOVE
      if (!state.GeometryValid) {
        actions.Add(api.Position(window, IntPtr.Zero, desired, 0x14)
          ? "bar geometry restored" : "bar geometry repair failed");
      }
      if (api.Message(0, ref data) == UIntPtr.Zero) {
        actions.Add("appbar registration failed; retry pending");
        return actions;
      }
      data.Rect = desired;
      if (api.Message(2, ref data) == UIntPtr.Zero) { // ABM_QUERYPOS
        api.Message(1, ref data);
        actions.Add("reservation query failed");
        return actions;
      }
      data.Rect.Bottom = data.Rect.Top + state.ExpectedHeight;
      if (!SafeReservation(state.Monitor, data.Rect, state.ExpectedHeight)) {
        api.Message(1, ref data);
        actions.Add("unsafe reservation query rejected; retry pending");
        return actions;
      }
      if (api.Message(3, ref data) == UIntPtr.Zero || // ABM_SETPOS can also adjust the rectangle.
          !SafeReservation(state.Monitor, data.Rect, state.ExpectedHeight)) {
        api.Message(1, ref data);
        actions.Add("unsafe or failed reservation released; retry pending");
        return actions;
      }
      bool moved = api.Position(window, IntPtr.Zero, data.Rect, 0x14); // NOZORDER | NOACTIVATE
      actions.Add(moved ? "reservation updated" : "bar reposition failed");
      return actions;
    }

    private static State Read(IntPtr window, int logicalHeight) {
      RECT rect;
      if (!GetWindowRect(window, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return null;
      MONITORINFO monitor = new MONITORINFO();
      monitor.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      if (!GetMonitorInfoW(MonitorFromWindow(window, 2), ref monitor)) return null;
      uint dpi = GetDpiForWindow(window);
      if (dpi < 96 || dpi > 768) return null; // A window can disappear during enumeration.
      return Describe(window.ToInt64(), rect, monitor.Monitor, monitor.Work,
        (GetWindowLongW(window, -20) & 0x8) != 0, dpi, logicalHeight);
    }
  }
}

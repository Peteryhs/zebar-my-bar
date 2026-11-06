namespace ZebarDock.Tests {
  using System;
  using System.Collections.Generic;

  // Compiled with bar-dock.cs: runs the real repair code against a fake shell,
  // including temporary 600px WebViews and stale oversized reservations.
  public static class Regression {
    private sealed class Shell : Guard.IAppBarApi {
      public readonly List<uint> Messages = new List<uint>();
      public readonly List<Guard.RECT> Moves = new List<Guard.RECT>();
      public readonly List<Guard.RECT> Reservations = new List<Guard.RECT>();
      public int ExistingHeight, QueryShift, CommitHeight;
      public bool FailRegister, FailQuery, FailCommit;
      public uint RegisterCallback() { return 123; }
      public UIntPtr Message(uint message, ref Guard.APPBARDATA data) {
        Assert(data.hWnd == new IntPtr(99), "Only the bar's own HWND may be changed.");
        Messages.Add(message);
        if (message == 1) ExistingHeight = 0;
        if (message == 0 && FailRegister) return UIntPtr.Zero;
        if (message == 2) {
          if (FailQuery) return UIntPtr.Zero;
          // A stale registration must be removed before querying, otherwise a
          // shell can offer a position beneath the old reserved strip.
          data.Rect.Top += ExistingHeight + QueryShift;
          data.Rect.Bottom += 600; // QUERYPOS need not preserve the height.
        }
        if (message == 3) {
          Reservations.Add(data.Rect);
          if (FailCommit) return UIntPtr.Zero;
          if (CommitHeight > 0) data.Rect.Bottom = data.Rect.Top + CommitHeight;
          ExistingHeight = data.Rect.Bottom - data.Rect.Top;
        }
        return new UIntPtr(1);
      }
      public bool Position(IntPtr window, IntPtr after, Guard.RECT rect, uint flags) {
        Assert((flags & 0x10) != 0, "Repairs must never activate a window.");
        if ((flags & 1) == 0) Moves.Add(rect);
        return true;
      }
    }

    private static void Assert(bool condition, string message) {
      if (!condition) throw new InvalidOperationException(message);
    }
    private static Guard.RECT Rect(int x, int y, int width, int height) {
      return new Guard.RECT { Left = x, Top = y, Right = x + width, Bottom = y + height };
    }
    private static Guard.State State(Guard.RECT monitor, int actualHeight, int reservedHeight, uint dpi, int logicalHeight, bool topmost) {
      return Guard.Describe(99, Rect(monitor.Left, monitor.Top, monitor.Right - monitor.Left, actualHeight), monitor,
        new Guard.RECT { Left = monitor.Left, Top = monitor.Top + reservedHeight, Right = monitor.Right, Bottom = monitor.Bottom },
        topmost, dpi, logicalHeight);
    }

    public static string[] Run(int logicalHeight) {
      List<string> reports = new List<string>();
      int cases = 0;
      foreach (uint dpi in new uint[] { 96, 120, 144, 168, 192, 216 }) {
        foreach (int x in new int[] { -2560, 0, 2560 }) {
          foreach (int y in new int[] { -1080, 0 }) {
            Guard.RECT monitor = Rect(x, y, 2560, 1440);
            int expected = (int)(logicalHeight * (dpi / 96.0));
            foreach (int actual in new int[] { expected, 600, 1080 }) {
              Shell shell = new Shell { ExistingHeight = 600 };
              Guard.State state = State(monitor, actual, 600, dpi, logicalHeight, true);
              Assert(!state.Reserved, "An oversized work-area offset must not count as healthy.");
              Guard.RepairWindow(shell, new IntPtr(99), state);
              Assert(shell.Messages[0] == 1, "Release stale space before querying a new reservation.");
              Assert(shell.ExistingHeight == expected, "Repair must reserve only the configured DPI-scaled height.");
              Assert(shell.Reservations.Count == 1 && shell.Reservations[0].Bottom == y + expected,
                "The reservation must end at the top strip, not inherit a transient window height.");
              foreach (Guard.RECT move in shell.Moves) {
                Assert(Guard.SafeReservation(monitor, move, expected), "Never apply oversized or displaced window bounds.");
              }
              int messages = shell.Messages.Count;
              int moves = shell.Moves.Count;
              Guard.State healthy = State(monitor, expected, expected, dpi, logicalHeight, true);
              for (int repeat = 0; repeat < 20; repeat++) {
                Assert(Guard.RepairWindow(shell, new IntPtr(99), healthy).Count == 0, "Healthy checks must be a no-op.");
              }
              Assert(shell.Messages.Count == messages && shell.Moves.Count == moves, "Repeated checks must not grow reservations.");
              cases++;
            }
          }
        }
      }
      reports.Add("PASS: " + cases + " oversized-window/reservation cases across six DPI scales and six monitor origins; 20 idle rechecks each.");

      Guard.RECT primary = Rect(0, 0, 1920, 1080);
      Guard.State lost = State(primary, logicalHeight, 0, 96, logicalHeight, true);
      Guard.State startup = State(primary, 600, 0, 96, logicalHeight, true);
      Assert(!Guard.ReadyForRepair(startup, 0) && !Guard.ReadyForRepair(startup, 999),
        "Do not race Zebar's initial WebView sizing and appbar registration.");
      Assert(Guard.ReadyForRepair(startup, 1000) && Guard.ReadyForRepair(lost, 0),
        "Persistent bad geometry and lost reservations must remain recoverable.");
      reports.Add("PASS: transient startup geometry is deferred; persistent faults and normal lost reservations are recoverable.");
      // Reproduce the delayed native initialization seen during laptop ->
      // external display switching: the old guard registered at four seconds,
      // while Zebar did not attempt its own ABM_NEW until nine seconds.
      long ticks = System.Diagnostics.Stopwatch.Frequency;
      Guard.State switching = State(primary, 600, 0, 96, logicalHeight, false);
      Assert(Guard.ObserveDisplay(switching, 0) == 0, "New HWND must receive startup grace.");
      Assert(Guard.ObserveDisplay(switching, 9 * ticks) < Guard.InitializationGraceMs,
        "Do not take ownership before delayed native registration at nine seconds.");
      Guard.State sized = State(primary, logicalHeight, 0, 96, logicalHeight, true);
      Assert(Guard.ObserveDisplay(sized, 10 * ticks) == 10000,
        "Final bounds alone must not end initialization grace.");
      Assert(Guard.ObserveDisplay(sized, 21 * ticks) >= Guard.InitializationGraceMs,
        "A persistently failed initialization must remain recoverable.");
      Guard.State moved = State(Rect(-2560, 0, 2560, 1440), logicalHeight, 0, 96, logicalHeight, true);
      Assert(Guard.ObserveDisplay(moved, 22 * ticks) == 0, "Changing monitors must renew grace on the same HWND.");
      Guard.State scaled = State(moved.Monitor, logicalHeight, 0, 144, logicalHeight, true);
      Assert(Guard.ObserveDisplay(scaled, 23 * ticks) == 0, "Changing DPI must renew initialization grace.");
      reports.Add("PASS: delayed native docking protected; final sizing does not end grace; monitor and DPI changes renew grace.");
      Shell shifted = new Shell { QueryShift = 420 };
      Guard.RepairWindow(shifted, new IntPtr(99), lost);
      Assert(shifted.Reservations.Count == 0 && shifted.ExistingHeight == 0,
        "Reject displaced queries before committing, rather than stacking reservations.");
      Shell inflated = new Shell { CommitHeight = 800 };
      Guard.RepairWindow(inflated, new IntPtr(99), lost);
      Assert(inflated.ExistingHeight == 0 && inflated.Moves.Count == 0,
        "If the shell inflates the commit, release it and never resize the window to match.");
      reports.Add("PASS: shifted query rejected; oversized commit released.");

      foreach (Shell failed in new Shell[] {
        new Shell { FailRegister = true }, new Shell { FailQuery = true }, new Shell { FailCommit = true }
      }) {
        Guard.RepairWindow(failed, new IntPtr(99), lost);
        Assert(failed.ExistingHeight == 0, "Failed repairs must not leak a reservation.");
      }
      Shell topmost = new Shell();
      Guard.RepairWindow(topmost, new IntPtr(99), State(primary, logicalHeight, logicalHeight, 96, logicalHeight, false));
      Assert(topmost.Messages.Count == 0 && topmost.Moves.Count == 0, "Restoring topmost must not renegotiate a healthy strip.");
      reports.Add("PASS: registration/query/commit failures leave no leaked space; topmost-only repair preserves geometry.");
      return reports.ToArray();
    }
  }
}

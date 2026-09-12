param(
  [Parameter(Mandatory = $true)][ValidateSet('get', 'set', 'serve')][string]$Action,
  [int]$Value = -1,
  [int]$IdleTimeoutSeconds = 300,
  [int]$TickMs = 15
)

# Brightness of the built in panel, through the WMI monitor classes. External
# monitors usually ignore this and need DDC/CI instead, in which case -1 is
# reported and the panel says so.
#
# The method call goes through Invoke-CimMethod: calling the method directly on
# a Get-CimInstance object reports "MethodNotFound" for these classes.
#
#   get    Print the current level and exit.
#   set    Apply -Value, print the resulting level, exit.
#   serve  Long lived. Reads levels from stdin, one integer per line, applies
#          each one straight away and prints the level it reached.
#
# `serve` exists because the slider has to follow the pointer. One PowerShell
# per slider step costs a few hundred milliseconds of process startup plus the
# WMI class lookup, so dragging lagged badly behind the pointer no matter how
# the calls were coalesced in the page. Here the process and the CIM instances
# are resolved once and a step is just a line on a pipe.

$monitorClass = 'WmiMonitorBrightness'
$methodClass = 'WmiMonitorBrightnessMethods'

function Get-Brightness {
  $monitor = Get-CimInstance -Namespace root/WMI -ClassName $monitorClass -ErrorAction SilentlyContinue

  if (-not $monitor) { return -1 }

  return [int]($monitor | Select-Object -First 1).CurrentBrightness
}

function Get-Methods {
  return @(Get-CimInstance -Namespace root/WMI -ClassName $methodClass -ErrorAction SilentlyContinue)
}

# Returns $true when the level was applied.
function Set-Brightness($methods, [int]$level) {
  $clamped = [Math]::Min(100, [Math]::Max(0, $level))

  foreach ($method in $methods) {
    try {
      [void](Invoke-CimMethod -InputObject $method -MethodName WmiSetBrightness -Arguments @{
          Timeout    = [uint32]1
          Brightness = [byte]$clamped
        })
    } catch {
      return $false
    }
  }

  return $true
}

if ($Action -eq 'get') {
  Write-Output (Get-Brightness)
  exit 0
}

if ($Action -eq 'set') {
  $methods = Get-Methods

  if ($methods.Count -eq 0) {
    Write-Output 'unsupported'
    exit 1
  }

  if (-not (Set-Brightness $methods $Value)) {
    Write-Output 'set failed'
    exit 1
  }

  Write-Output (Get-Brightness)
  exit 0
}

# -Action serve

# Retire servers left behind by an earlier panel. Closing a widget destroys its
# page without necessarily running unload handlers, so without this a server is
# left holding a pipe nobody reads every time the panel is opened.
$selfScript = $MyInvocation.MyCommand.Path
try {
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
    Where-Object {
      $_.ProcessId -ne $PID -and $_.CommandLine -like "*$selfScript*" -and $_.CommandLine -like '*serve*'
    } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
} catch {
  # Process listing unavailable: an extra server is harmless, it just idles out.
}

$methods = Get-Methods

if ($methods.Count -eq 0) {
  Write-Output 'unsupported'
  exit 1
}

$stdin = New-Object System.IO.StreamReader ([Console]::OpenStandardInput())
$pendingRead = $stdin.ReadLineAsync()
$lastActivity = Get-Date
$ticks = 0

function Write-Line([string]$text) {
  [Console]::Out.WriteLine($text)
  [Console]::Out.Flush()
}

# Report the starting level, so the panel can draw the slider without a separate
# one-shot call.
Write-Line (Get-Brightness)

while ($true) {
  # Drain everything queued and keep only the newest level. A fast drag puts
  # dozens of lines on the pipe and only the last one is worth applying; the
  # ones in between describe positions the pointer has already left.
  $wanted = $null
  $quit = $false

  while ($pendingRead.IsCompleted) {
    $line = $null

    try {
      $line = $pendingRead.Result
    } catch {
      $line = $null
    }

    if ($null -eq $line) {
      # stdin closed: the panel is gone.
      $quit = $true
      break
    }

    $pendingRead = $stdin.ReadLineAsync()
    $trimmed = $line.Trim()

    if ($trimmed -eq 'quit') {
      $quit = $true
      break
    }

    # The panel sends this once on startup and only trusts the pipe after the
    # answer comes back. Writing to a spawned process's stdin is the one part of
    # this that the page cannot check any other way: a write that goes nowhere
    # looks exactly like a write that worked.
    if ($trimmed -eq 'ping') {
      Write-Line 'pong'
      $lastActivity = Get-Date
      continue
    }

    if ($trimmed -eq 'get') {
      Write-Line (Get-Brightness)
      $lastActivity = Get-Date
      continue
    }

    $parsed = 0
    if ([int]::TryParse($trimmed, [ref]$parsed)) {
      $wanted = $parsed
    }
  }

  if ($quit) { break }

  if ($null -ne $wanted) {
    $lastActivity = Get-Date
    $applied = Set-Brightness $methods $wanted

    try {
      Write-Line $(if ($applied) { $wanted } else { 'set failed' })
    } catch {
      # Nobody is listening any more.
      break
    }
  }

  # Every ~3 seconds: give up if nothing has asked for a change in a while, or
  # if Zebar is gone. A stray server must not outlive the bar.
  $ticks++
  if (($ticks * $TickMs) -ge 3000) {
    $ticks = 0

    if (((Get-Date) - $lastActivity).TotalSeconds -gt $IdleTimeoutSeconds) {
      break
    }

    if (-not (Get-Process -Name zebar -ErrorAction SilentlyContinue)) {
      break
    }
  }

  Start-Sleep -Milliseconds $TickMs
}

exit 0

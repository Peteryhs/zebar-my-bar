param(
  [Parameter(Mandatory = $true)][ValidateSet('get', 'set')][string]$Action,
  [int]$Value = -1
)

# Brightness of the built in panel, through the WMI monitor classes. External
# monitors usually ignore this and need DDC/CI instead, in which case -1 is
# reported and the panel says so.
#
# The method call goes through Invoke-CimMethod: calling the method directly on a
# Get-CimInstance object reports "MethodNotFound" for these classes.
#
# One process per change, which costs a couple of hundred milliseconds of startup.
# There was a long lived version of this that took levels on stdin, so a drag cost
# nothing per step; it had to go, because zebar's shellWrite resolves without
# delivering anything and the process sat waiting for lines that never came. The
# panel coalesces instead: one call in flight, newest value wins.

function Get-Brightness {
  $monitor = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue

  if (-not $monitor) { return -1 }

  return [int]($monitor | Select-Object -First 1).CurrentBrightness
}

if ($Action -eq 'get') {
  Write-Output (Get-Brightness)
  exit 0
}

$methods = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue)

if ($methods.Count -eq 0) {
  Write-Output 'unsupported'
  exit 1
}

$level = [Math]::Min(100, [Math]::Max(0, $Value))

foreach ($method in $methods) {
  try {
    [void](Invoke-CimMethod -InputObject $method -MethodName WmiSetBrightness -Arguments @{
        Timeout    = [uint32]1
        Brightness = [byte]$level
      })
  } catch {
    Write-Output ('set failed: ' + $_.Exception.Message)
    exit 1
  }
}

Write-Output (Get-Brightness)

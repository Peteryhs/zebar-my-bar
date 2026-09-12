param(
  [Parameter(Mandatory = $true)][ValidateSet('sleep', 'lock', 'signout', 'shutdown', 'restart')][string]$Action
)

# Power actions for the bar's menu widget. Kept in a script so the shell
# privilege in zpack.json only has to allow this one file.

switch ($Action) {
  'sleep' {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    [System.Windows.Forms.Application]::SetSuspendState(
      [System.Windows.Forms.PowerState]::Suspend, $false, $false)
  }
  'lock' {
    Start-Process 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation'
  }
  'signout' {
    Start-Process 'shutdown.exe' -ArgumentList '/l'
  }
  'shutdown' {
    Start-Process 'shutdown.exe' -ArgumentList '/s', '/t', '0'
  }
  'restart' {
    Start-Process 'shutdown.exe' -ArgumentList '/r', '/t', '0'
  }
}

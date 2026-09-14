# calendar.ps1
#
# Prints the raw iCalendar text of every feed listed in
#
#   %USERPROFILE%\.glzr\calendar-feeds.txt      one URL per line, # for comments
#
# and nothing at all if that file does not exist. The calendar panel parses what
# comes back; this only fetches.
#
# Why a script rather than fetch() in the page: Google does not send CORS headers
# for its iCal export, so the webview refuses to read it. This has no such rule.
#
# Why the URLs live in a file instead of being passed in: a Google secret iCal
# address is a credential — anyone holding it can read the calendar — so it stays
# out of the widget pack, out of version control, and out of the shell command the
# widget is allowed to run. The widget cannot name a URL, so this cannot be talked
# into fetching an arbitrary one.
#
# Get the address from Google Calendar: Settings, pick the calendar, "Integrate
# calendar", "Secret address in iCal format". Note that Google's export can lag
# live edits by a few hours; it is not a live view.

param(
  # Responses are cached, so opening the panel repeatedly does not refetch.
  [int]$CacheMinutes = 15,
  # Bypass the cache and force a fresh download.
  [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'

$feedFile = Join-Path $env:USERPROFILE '.glzr\calendar-feeds.txt'
$cacheFile = Join-Path $env:TEMP 'zebar-calendar-cache.ics'

if (-not (Test-Path $feedFile)) {
  # No feeds configured. The panel shows the month on its own.
  exit 0
}

$urls = @(
  Get-Content $feedFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }
)

if ($urls.Count -eq 0) { exit 0 }

# Fresh enough cache wins unless forced or the feeds file was edited since.
if ((-not $Force) -and (Test-Path $cacheFile)) {
  $cacheItem = Get-Item $cacheFile
  $feedItem = Get-Item $feedFile
  $cacheAge = (Get-Date) - $cacheItem.LastWriteTime

  if (($cacheAge.TotalMinutes -lt $CacheMinutes) -and ($feedItem.LastWriteTime -le $cacheItem.LastWriteTime)) {
    Get-Content $cacheFile -Raw
    exit 0
  }
}

# TLS 1.2 for PowerShell 5.1, whose default is older than anything Google accepts.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  # Newer hosts already do the right thing.
}

$parts = New-Object System.Collections.ArrayList

foreach ($url in $urls) {
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
    [void]$parts.Add([string]$response.Content)
  } catch {
    # One unreachable feed must not lose the others.
    continue
  }
}

if ($parts.Count -eq 0) {
  # Nothing fetched. Serve a stale cache rather than showing an empty calendar.
  if (Test-Path $cacheFile) {
    Get-Content $cacheFile -Raw
  }

  exit 0
}

$all = $parts -join "`r`n"

try {
  Set-Content -Path $cacheFile -Value $all -Encoding UTF8
} catch {
  # The cache is an optimisation.
}

Write-Output $all

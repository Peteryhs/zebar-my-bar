# Read once when a helper starts. Never infer the reservation from a live HWND:
# a newly created WebView may still have its temporary 800x600 window size.
function Get-BarDockHeight {
  $configPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'zpack.json'
  $pack = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  $presets = @($pack.widgets | Where-Object name -eq 'vanilla' |
    ForEach-Object { $_.presets } | Where-Object { $_.dockToEdge.enabled -and $_.dockToEdge.edge -eq 'top' })
  $heights = @($presets | ForEach-Object { $_.height } | Select-Object -Unique)
  if ($heights.Count -ne 1 -or $heights[0] -notmatch '^(\d+)px$') {
    throw 'Dock recovery needs one fixed pixel height for the top bar.'
  }
  $height = [int]$Matches[1]
  if ($height -lt 16 -or $height -gt 128) { throw 'Configured bar height must be between 16px and 128px.' }
  return $height
}

# Local static server for the trading terminal (VPS rehearsal).
# Serves C:\Users\klyde\trading-sim\report\ at http://localhost:8377/
# Usage:  powershell -ExecutionPolicy Bypass -File start_terminal.ps1          (server loop, blocks)
#         powershell ... start_terminal.ps1 -Launch                            (spawn hidden server + open browser)
param([switch]$Launch)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\klyde\trading-sim\report'
$prefix = 'http://localhost:8377/'

if ($Launch) {
  # already running? then just open the browser
  $up = $false
  try { $null = Invoke-WebRequest -Uri ($prefix + 'trades.html') -TimeoutSec 3 -UseBasicParsing; $up = $true } catch {}
  if (-not $up) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    Start-Sleep -Seconds 2
  }
  Start-Process ($prefix + 'chart.html')
  return
}

$mime = @{ '.html'='text/html; charset=utf-8'; '.js'='application/javascript; charset=utf-8'
           '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8'
           '.png'='image/png'; '.svg'='image/svg+xml'; '.ico'='image/x-icon' }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() }
catch { Write-Host "Port busy - server already running at $prefix"; return }
Write-Host "Terminal server running at $prefix (root: $root). Ctrl+C to stop."
while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = 'chart.html' }
    $file = Join-Path $root ($path -replace '/', '\')
    # no path traversal
    if ($file -notlike "$root*" -or -not (Test-Path $file -PathType Leaf)) {
      $ctx.Response.StatusCode = 404
      $b = [Text.Encoding]::UTF8.GetBytes('404')
      $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close(); continue
    }
    $ext = [IO.Path]::GetExtension($file).ToLower()
    $ctx.Response.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
    $ctx.Response.Headers.Add('Cache-Control','no-cache')
    $bytes = [IO.File]::ReadAllBytes($file)
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
  } catch { }
}

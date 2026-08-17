# Offline contract test for the T-Invest mock call log. No token or network is used.
$ErrorActionPreference = 'Stop'

function Assert-That([string]$Name, [bool]$Condition) {
  if (-not $Condition) { throw "failed: $Name" }
  Write-Host "ok  $Name"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ti-mock-contract-" + [guid]::NewGuid().ToString('N'))
try {
  $mock = Join-Path $root 'mock'
  New-Item -ItemType Directory -Force $mock | Out-Null
  [IO.File]::WriteAllText((Join-Path $mock 'OrdersService.PostOrder.json'), '{"orderId":"mock-order"}')

  $env:TINVEST_MOCK_DIR = $mock
  $env:TINVEST_ACCOUNT_ID = 'acc-contract'
  $env:TINVEST_TOKEN = 'offline-only'
  . (Join-Path $PSScriptRoot 'lib_engine.ps1')
  . (Join-Path $PSScriptRoot 'lib_tinvest.ps1')
  Initialize-TInvest (Join-Path $root 'data') 'prod' 'acc-contract'

  $body = [ordered]@{
    accountId = 'acc-contract'
    orderId = '00000000-0000-0000-0000-000000000001'
    instrumentId = 'FUTNGU6'
    quantity = 1
  }
  $response = Invoke-TInvest 'OrdersService' 'PostOrder' $body -Mutating
  Assert-That 'mock response is returned' ($response.orderId -eq 'mock-order')

  $line = Get-Content (Join-Path $mock 'calls_log.jsonl') -Encoding UTF8 -Raw | ConvertFrom-Json
  Assert-That 'service is preserved' ($line.service -eq 'OrdersService')
  Assert-That 'method is preserved' ($line.method -eq 'PostOrder')
  Assert-That 'body remains a JSON string for legacy consumers' ($line.body -is [string])
  $loggedBody = $line.body | ConvertFrom-Json
  Assert-That 'body can be parsed once after reading JSONL' ($loggedBody.orderId -eq $body.orderId -and $loggedBody.instrumentId -eq $body.instrumentId)
  Write-Host 'T-Invest mock-log contract passed.'
}
finally {
  $env:TINVEST_MOCK_DIR = $null
  $env:TINVEST_ACCOUNT_ID = $null
  $env:TINVEST_TOKEN = $null
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

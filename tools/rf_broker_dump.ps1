# rf_broker_dump.ps1 - снимок брокерских данных боевого RF-контура ТОЛЬКО ДЛЯ ЧТЕНИЯ.
# Этап 0 риск-политики: сверка закрытых сделок с брокером (исполнения, комиссии, вариационка) и
# проверка, какими полями брокер связывает заявки, операции и комиссии.
# Безопасность:
#   - работает только при TINVEST_MODE=dryrun: клиент перехватывает мутирующие вызовы до транспорта,
#     а сам скрипт мутирующих методов не вызывает вовсе;
#   - пишет только в каталог -Out; data/live_rf не трогает (эту папку коммитит тик на VPS);
#   - токен в выгрузку не попадает, номер счёта маскируется.
# Запуск на VPS (токен есть только там):
#   set -a; . /etc/trading-live.env; set +a
#   TINVEST_MODE=dryrun pwsh -NoProfile -File rf_broker_dump.ps1 -RepoRoot /home/trader/paper-desk -Out /tmp/rf_snapshot_<ts>
# Выгрузка содержит финансовые данные счёта: хранить только в приватной папке (strategy_lab/ в .gitignore).
param(
  [string]$Out = '',
  [string]$From = '2026-07-10T00:00:00Z',
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Stop'
if ([string]$env:TINVEST_MODE -ne 'dryrun') { throw 'rf_broker_dump: запускать только с TINVEST_MODE=dryrun (защита от мутаций)' }
if (-not $RepoRoot) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
. (Join-Path $RepoRoot 'tools/lib_engine.ps1')
. (Join-Path $RepoRoot 'tools/lib_tinvest.ps1')
$nowUtc = (Get-Date).ToUniversalTime()
if (-not $Out) { $Out = Join-Path ([IO.Path]::GetTempPath()) ('rf_snapshot_' + $nowUtc.ToString('yyyyMMddTHHmmssZ')) }
$lrf = Join-Path $RepoRoot 'data/live_rf'
if ([IO.Path]::GetFullPath($Out).StartsWith([IO.Path]::GetFullPath($lrf))) { throw 'rf_broker_dump: -Out внутри data/live_rf запрещён (папку коммитит тик)' }
New-Item -ItemType Directory -Force $Out | Out-Null
Initialize-TInvest (Join-Path $Out '_client') 'dryrun'
$acc = [string]$env:TINVEST_ACCOUNT_ID
if (-not $acc) { throw 'rf_broker_dump: нет TINVEST_ACCOUNT_ID' }
$toIso = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$files = [ordered]@{}

function Save-Dump([string]$Name, $Obj, [string]$Source) {
  $p = Join-Path $Out $Name
  # массив, пришедший параметром, ConvertTo-Json оборачивает в {"value":[...],"Count":N} -
  # сериализуем чистым [object[]] (та же гочка проекта, что с массивами из ConvertFrom-Json)
  $payload = $Obj
  if ($Obj -is [System.Array] -or $Obj -is [System.Collections.IList]) { $payload = [object[]]@($Obj | ForEach-Object { $_ }) }
  [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $payload -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
  $files[$Name] = [ordered]@{ sha256 = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower(); source = $Source
    fetched_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
  Write-Host ("  {0}  <- {1}" -f $Name, $Source)
}
function Copy-Local([string]$Rel) {
  $src = Join-Path $RepoRoot $Rel
  if (-not (Test-Path $src)) { return }
  $name = 'repo_' + ($Rel -replace '[\\/]', '_')
  $dst = Join-Path $Out $name
  Copy-Item $src $dst -Force
  $files[$name] = [ordered]@{ sha256 = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower(); source = "repo:$Rel"
    mtime_utc = (Get-Item $src).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
}

Write-Host "rf_broker_dump -> $Out"
# 1. стоп-заявки всех статусов: какие стопы/TP1 сняты, исполнены, истекли; дубли и сироты
Save-Dump 'stop_orders_all.json' (Invoke-TInvest 'StopOrdersService' 'GetStopOrders' @{ accountId = $acc
  status = 'STOP_ORDER_STATUS_ALL'; from = $From; to = $toIso }) 'StopOrdersService.GetStopOrders(ALL)'
# 2. портфель и позиции на момент выгрузки
Save-Dump 'portfolio.json' (Get-TiPortfolio $acc) 'OperationsService.GetPortfolio'
Save-Dump 'positions.json' (Get-TiPositions $acc) 'OperationsService.GetPositions'
# 3a. операции окнами по 31 день - тот же метод, которым пользуется движок
$ops = New-Object System.Collections.Generic.List[object]
$a = [DateTimeOffset]::Parse($From).ToUnixTimeMilliseconds()
$b = [DateTimeOffset]::Parse($toIso).ToUnixTimeMilliseconds()
while ($a -lt $b) {
  $e = [math]::Min($a + 31L * 86400000, $b)
  foreach ($o in @(Get-TiOperations $acc ((MsToUtc $a).ToString('yyyy-MM-ddTHH:mm:ssZ')) ((MsToUtc $e).ToString('yyyy-MM-ddTHH:mm:ssZ')))) {
    if ($null -ne $o) { $ops.Add($o) }
  }
  $a = $e
}
Save-Dump 'operations.json' ($ops.ToArray()) "OperationsService.GetOperations EXECUTED $From..$toIso"
# 3b. то же курсором: у каждой операции есть комиссия и сделки (trades_info) - они и нужны для сверки
$items = New-Object System.Collections.Generic.List[object]
$cursor = ''; $pages = 0; $r = $null
do {
  $body = @{ accountId = $acc; from = $From; to = $toIso; limit = 1000; withoutCommissions = $false; withoutTrades = $false }
  if ($cursor) { $body.cursor = $cursor }
  $r = Invoke-TInvest 'OperationsService' 'GetOperationsByCursor' $body
  foreach ($it in @($r.items)) { if ($null -ne $it) { $items.Add($it) } }
  $cursor = [string]$r.nextCursor
  $pages++
} while ($r.hasNext -and $cursor -and $pages -lt 50)
Save-Dump 'operations_by_cursor.json' ($items.ToArray()) "OperationsService.GetOperationsByCursor $From..$toIso pages=$pages"
# 4. инструменты, которыми торговал бот: шаг цены и его стоимость НА СЕГОДНЯ (истёкший контракт брокер может не отдать)
$tickers = New-Object System.Collections.Generic.List[string]
foreach ($x in @(Read-JsonFile (Join-Path $lrf 'trades.json'))) { if ($null -ne $x -and $x.secid -and -not $tickers.Contains([string]$x.secid)) { $tickers.Add([string]$x.secid) } }
$pf = Read-JsonFile (Join-Path $lrf 'portfolio.json')
foreach ($sn in 'core','setA') {
  foreach ($c in @($pf.sleeves.$sn.positions)) { if ($null -ne $c -and $c.secid -and -not $tickers.Contains([string]$c.secid)) { $tickers.Add([string]$c.secid) } }
}
$inst = [ordered]@{}
foreach ($t in $tickers) {
  try {
    $i = Get-TiInstrument $t 'fut'
    $inst[$t] = [ordered]@{ instrument = $i; margin = (Get-TiFuturesMargin ([string]$i.uid)) }
  } catch { $inst[$t] = [ordered]@{ error = [string]$_.Exception.Message } }
}
Save-Dump 'instruments.json' $inst 'InstrumentsService.FutureBy + GetFuturesMargin'
# 5. локальное состояние бота и версия кода, от которых считалась выгрузка
foreach ($rel in 'data/live_rf/portfolio.json', 'data/live_rf/trades.json', 'data/live_rf/equity.json', 'data/live_rf/config.json') { Copy-Local $rel }
$head = ''
try { $head = [string](& git -c "safe.directory=$RepoRoot" -C $RepoRoot rev-parse HEAD 2>$null) } catch {}
$manifest = [ordered]@{ tool = 'rf_broker_dump.ps1'; created_utc = $toIso; from = $From; to = $toIso
  account = ('***' + $acc.Substring([math]::Max(0, $acc.Length - 4))); repo_head = $head; mode = 'dryrun'; files = $files }
[IO.File]::WriteAllText((Join-Path $Out 'manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Remove-Item (Join-Path $Out '_client') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "готово: $Out"

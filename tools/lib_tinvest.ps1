# lib_tinvest.ps1 - клиент T-Invest API v2 (Т-Инвестиции) через REST-gateway (gRPC-JSON transcoding).
# Используется live_rf_engine.ps1 (LIVE-контур C3b) и tinvest_selftest.ps1.
# Дизайн: docs\strategy\live_tinvest_design.md. Поля/эндпоинты, помеченные VERIFY, требуют
# подтверждения по докам/бою в Phase 1 (readonly-токен) - см. реестр открытых вопросов.
#
# Режимы (env TINVEST_MODE): prod | sandbox | dryrun. Плюс mock-транспорт (TINVEST_MOCK_DIR) для
# тестов без сети: ответы из сценарной очереди scenario.json либо фикстур {Service}.{Method}.json.
# DRYRUN: мутирующие вызовы логируются как WOULD CALL и возвращают синтетический успех.
#
# Ключевой принцип надёжности: мутирующие вызовы (PostOrder/CancelOrder/PostStopOrder/CancelStopOrder)
# НИКОГДА не ретраятся транспортом вслепую - при сетевом сбое возвращается { __lost = $true },
# и разрешение делает state machine движка (adopt по клиентскому order_id). Требует lib_engine.ps1.

# ================= init / config =================
$script:TI = @{
  mode = 'dryrun'; token = ''; base = ''; dataDir = ''; mockDir = ''
  accountId = ''; latencyCsv = ''; wouldLog = ''
}

function Initialize-TInvest([string]$DataDir, [string]$Mode = '', [string]$AccountId = '') {
  if (-not $Mode) { $Mode = if ($env:TINVEST_MODE) { $env:TINVEST_MODE } else { 'dryrun' } }
  $script:TI.mode = $Mode.ToLower()
  $script:TI.dataDir = $DataDir
  if ($DataDir -and -not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force $DataDir | Out-Null }
  $script:TI.latencyCsv = if ($DataDir) { Join-Path $DataDir 'latency_log.csv' } else { '' }
  $script:TI.wouldLog = if ($DataDir) { Join-Path $DataDir 'dryrun_calls.log' } else { '' }
  $script:TI.mockDir = [string]$env:TINVEST_MOCK_DIR
  $script:TI.accountId = if ($AccountId) { $AccountId } else { [string]$env:TINVEST_ACCOUNT_ID }
  switch ($script:TI.mode) {
    'sandbox' {
      $script:TI.token = [string]$env:TINVEST_SANDBOX_TOKEN
      $script:TI.base = 'https://sandbox-invest-public-api.tinkoff.ru/rest'   # VERIFY: хост песочницы
    }
    default {
      $script:TI.token = [string]$env:TINVEST_TOKEN
      $script:TI.base = 'https://invest-public-api.tinkoff.ru/rest'
    }
  }
}

$script:TI_MUTATING = @('OrdersService.PostOrder','OrdersService.CancelOrder',
  'StopOrdersService.PostStopOrder','StopOrdersService.CancelStopOrder')

function Write-TiLatency([string]$Service, [string]$Method, [int]$Ms, [string]$Status, [bool]$Ok) {
  if (-not $script:TI.latencyCsv) { return }
  try {
    if (-not (Test-Path $script:TI.latencyCsv)) {
      [IO.File]::AppendAllText($script:TI.latencyCsv, "utc,service,method,ms,status,ok`r`n")
    }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    [IO.File]::AppendAllText($script:TI.latencyCsv, "$ts,$Service,$Method,$Ms,$Status,$Ok`r`n")
    $fi = Get-Item $script:TI.latencyCsv
    if ($fi.Length -gt 2MB) {   # ротация ~30 дней полинга
      $keep = Get-Content $script:TI.latencyCsv -Tail 20000
      Set-Content $script:TI.latencyCsv $keep -Encoding UTF8
    }
  } catch {}
}

# ================= mock-транспорт (тесты без сети) =================
# scenario.json: { "queue": [ { "service","method","body_like"(опц. подстрока JSON тела),
#   "response": {...} | "error": "network" | "http": 429/400/500, "message": "..." } ],
#   плюс фикстуры-дефолты {Service}.{Method}.json в том же каталоге.
# Потребление очереди персистится в scenario_state.json (тесты гоняют движок несколькими процессами).
# Все вызовы логируются в calls_log.jsonl для assert'ов.
function Invoke-TiMock([string]$Service, [string]$Method, [string]$BodyJson) {
  $dir = $script:TI.mockDir
  $scnPath = Join-Path $dir 'scenario.json'
  $stPath = Join-Path $dir 'scenario_state.json'
  # лог вызова
  try {
    $rec = ConvertTo-Json -InputObject ([pscustomobject]@{ service = $Service; method = $Method; body = $BodyJson }) -Compress -Depth 5
    [IO.File]::AppendAllText((Join-Path $dir 'calls_log.jsonl'), "$rec`r`n")
  } catch {}
  if (Test-Path $scnPath) {
    $scn = Read-JsonFile $scnPath
    $st = Read-JsonFile $stPath
    $consumed = @{}
    if ($null -ne $st) { foreach ($ix in @($st.consumed)) { $consumed[[int]$ix] = $true } }
    $q = @($scn.queue)
    for ($i = 0; $i -lt $q.Count; $i++) {
      if ($consumed.ContainsKey($i)) { continue }
      $e = $q[$i]
      if ([string]$e.service -ne $Service -or [string]$e.method -ne $Method) { continue }
      if ($e.PSObject.Properties['body_like'] -and $e.body_like -and ($BodyJson -notlike "*$($e.body_like)*")) { continue }
      # потребить
      $newConsumed = @(@($consumed.Keys | ForEach-Object { [int]$_ }) + $i)
      Write-JsonAtomic $stPath ([pscustomobject]@{ consumed = $newConsumed }) 3
      if ($e.PSObject.Properties['error'] -and [string]$e.error -eq 'network') {
        throw (New-Object System.Net.WebException("mock network error"))
      }
      if ($e.PSObject.Properties['http'] -and [int]$e.http -gt 0) {
        $msg = if ($e.PSObject.Properties['message']) { [string]$e.message } else { 'mock http error' }
        throw ("TINVEST_HTTP_$($e.http): $msg")
      }
      return $e.response
    }
  }
  # дефолт-фикстура
  $fx = Join-Path $dir "$Service.$Method.json"
  if (Test-Path $fx) { return (Read-JsonFile $fx) }
  throw "mock: нет ни сценария, ни фикстуры для $Service.$Method"
}

# ================= транспорт =================
# Возврат: объект ответа. Для -Mutating при сетевом сбое: [pscustomobject]@{ __lost = $true; error = '...' }
# (заявка МОГЛА встать у брокера - разрешает state machine). HTTP 4xx -> исключение "TINVEST_HTTP_код: сообщение".
function Invoke-TInvest([string]$Service, [string]$Method, $Body = @{}, [switch]$Mutating,
                        [int]$Retries = 2, [int]$TimeoutSec = 15) {
  $bodyJson = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
  # DRYRUN: мутирующие вызовы перехватываются ДО ЛЮБОГО транспорта (включая mock) - гарантия «ноль мутаций»
  if ($script:TI.mode -eq 'dryrun' -and $script:TI_MUTATING -contains "$Service.$Method") {
    $line = "WOULD CALL $Service.$Method $bodyJson"
    if ($script:TI.wouldLog) { try { [IO.File]::AppendAllText($script:TI.wouldLog, "$((Get-Date).ToUniversalTime().ToString('u')) $line`r`n") } catch {} }
    return [pscustomobject]@{ __dryrun = $true; orderId = "dryrun-$([guid]::NewGuid().ToString('N').Substring(0,12))"
      executionReportStatus = 'EXECUTION_REPORT_STATUS_NEW'; stopOrderId = 'dryrun-stop' }
  }
  # mock-транспорт
  if ($script:TI.mockDir) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $r = Invoke-TiMock $Service $Method $bodyJson
      Write-TiLatency $Service $Method $sw.ElapsedMilliseconds 'mock' $true
      return $r
    } catch [System.Net.WebException] {
      Write-TiLatency $Service $Method $sw.ElapsedMilliseconds 'mock-net' $false
      if ($Mutating) { return [pscustomobject]@{ __lost = $true; error = $_.Exception.Message } }
      throw
    }
  }
  if (-not $script:TI.token) { throw "TINVEST: токен не задан (env TINVEST_TOKEN / TINVEST_SANDBOX_TOKEN)" }
  $url = "$($script:TI.base)/tinkoff.public.invest.api.contract.v1.$Service/$Method"
  $headers = @{ Authorization = "Bearer $($script:TI.token)"; 'Content-Type' = 'application/json' }
  $maxTry = if ($Mutating) { 1 } else { 1 + $Retries }   # мутации: одна попытка на транспортном уровне
  for ($try = 1; $try -le $maxTry; $try++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bodyJson -TimeoutSec $TimeoutSec -UseBasicParsing
      Write-TiLatency $Service $Method $sw.ElapsedMilliseconds ([string]$resp.StatusCode) $true
      # PS 5.1 декодирует Content по charset заголовка (часто отсутствует -> latin1 -> кириллица бьётся);
      # декодируем сырые байты как UTF-8 явно (боевой факт селфтеста 2026-07-17)
      $raw = $resp.RawContentStream
      if ($null -ne $raw) {
        $raw.Position = 0
        $txt = (New-Object IO.StreamReader($raw, [Text.Encoding]::UTF8)).ReadToEnd()
        if ($txt) { return ($txt | ConvertFrom-Json) } else { return $null }
      }
      if ([string]$resp.Content) { return ($resp.Content | ConvertFrom-Json) } else { return $null }
    } catch [System.Net.WebException] {
      $ms = $sw.ElapsedMilliseconds
      $http = 0; $respBody = ''
      $wr = $_.Exception.Response
      if ($null -ne $wr) {
        $http = [int]$wr.StatusCode
        try { $rd = New-Object IO.StreamReader($wr.GetResponseStream()); $respBody = $rd.ReadToEnd(); $rd.Close() } catch {}
      }
      Write-TiLatency $Service $Method $ms ([string]$http) $false
      if ($http -eq 0) {
        # чистая сетевая ошибка / таймаут
        if ($Mutating) { return [pscustomobject]@{ __lost = $true; error = $_.Exception.Message } }
        if ($try -lt $maxTry) { Start-Sleep -Milliseconds (500 * [math]::Pow(4, $try - 1)); continue }
        throw
      }
      $msg = $respBody
      try { $j = $respBody | ConvertFrom-Json; if ($j.message) { $msg = [string]$j.message } } catch {}
      # REST-gateway кладёт текст ошибки в grpc-trailer-message при пустом теле (боевой факт 2026-07-17)
      if (-not $msg) { try { $msg = [string]$wr.Headers['grpc-trailer-message'] } catch {} }
      if ($http -eq 429) {
        $reset = 5
        try { $h = $wr.Headers['x-ratelimit-reset']; if ($h) { $reset = [math]::Min([int]$h, 60) } } catch {}
        # мутации на 429 повторять БЕЗОПАСНО: order_id идемпотентен (подтверждено песочницей 2026-07-17
        # «The order is a duplicate») - один повтор с тем же ключом после паузы
        if ($Mutating -and $try -eq 1) { Start-Sleep -Seconds $reset; $maxTry = 2; continue }
        if ($try -lt $maxTry) { Start-Sleep -Seconds $reset; continue }
      }
      if ($http -ge 500 -and $try -lt $maxTry -and -not $Mutating) { Start-Sleep -Seconds (2 * $try); continue }
      # повтор идемпотентного order_id: «duplicate» = заявка уже принята (боевой факт 2026-07-17,
      # вариант «...but the order report was not found») -> НЕ ошибка: state machine дождётся
      # подтверждения через operations (adopt)
      if ($Mutating -and $msg -match 'duplicate') { return [pscustomobject]@{ __dup = $true; error = $msg } }
      throw "TINVEST_HTTP_$http" + ": $Service.$Method $msg"
    }
  }
}

# ================= конвертеры Quotation / MoneyValue =================
# Quotation { units: int64(строка в JSON), nano: int32 }; nano = 1e-9, знак совпадает с units
function Q2D($q) {
  if ($null -eq $q) { return [decimal]0 }
  $u = [decimal]0; $n = [decimal]0
  if ($q.PSObject.Properties['units'] -and $null -ne $q.units -and [string]$q.units -ne '') { $u = [decimal][string]$q.units }
  if ($q.PSObject.Properties['nano'] -and $null -ne $q.nano) { $n = [decimal]$q.nano }
  return $u + $n / [decimal]1000000000
}
function D2Q([decimal]$v) {
  $u = [decimal][math]::Truncate($v)
  $n = [int](($v - $u) * [decimal]1000000000)
  # gRPC-JSON: int64 сериализуется строкой
  return @{ units = ([long]$u).ToString([Globalization.CultureInfo]::InvariantCulture); nano = $n }
}
function M2D($money) {
  # MoneyValue -> @{ value; currency }
  $cur = if ($null -ne $money -and $money.PSObject.Properties['currency']) { [string]$money.currency } else { '' }
  return [pscustomobject]@{ value = (Q2D $money); currency = $cur }
}
# поле в snake_case ИЛИ camelCase (REST-gateway отдаёт camelCase - боевой факт селфтеста 2026-07-17)
function Get-TiField($Obj, [string]$Snake) {
  if ($null -eq $Obj) { return $null }
  if ($Obj.PSObject.Properties[$Snake]) { return $Obj.$Snake }
  $camel = [regex]::Replace($Snake, '_(.)', { $args[0].Groups[1].Value.ToUpper() })
  if ($Obj.PSObject.Properties[$camel]) { return $Obj.$camel }
  return $null
}
# рублей за 1 пункт цены фьючерса: min_price_increment_amount / min_price_increment
# КРИТИЧНО для сайзинга (боевой нюанс №1: цены фьючерсов в пунктах, НЕ в рублях)
function Get-RubPerPoint($futInfo) {
  $inc = Q2D (Get-TiField $futInfo 'min_price_increment')
  $amt = Q2D (Get-TiField $futInfo 'min_price_increment_amount')
  if ($inc -le 0 -or $amt -le 0) { throw "Get-RubPerPoint: нет min_price_increment(_amount) у $($futInfo.ticker)" }
  return $amt / $inc
}
function Convert-PtsToRub([decimal]$Pts, $futInfo) { return $Pts * (Get-RubPerPoint $futInfo) }
function Round-ToIncrement([decimal]$Px, $futInfo) {
  $inc = Q2D (Get-TiField $futInfo 'min_price_increment')
  if ($inc -le 0) { return $Px }
  return [math]::Round([math]::Round($Px / $inc) * $inc, 9)
}

# ================= инструменты =================
# kind: 'fut' (class_code SPBFUT) | 'share' (TQBR)
function Get-TiInstrument([string]$Ticker, [string]$Kind) {
  if ($Kind -eq 'fut') {
    $r = Invoke-TInvest 'InstrumentsService' 'FutureBy' @{ idType = 'INSTRUMENT_ID_TYPE_TICKER'; classCode = 'SPBFUT'; id = $Ticker }
    return $r.instrument
  } else {
    $r = Invoke-TInvest 'InstrumentsService' 'ShareBy' @{ idType = 'INSTRUMENT_ID_TYPE_TICKER'; classCode = 'TQBR'; id = $Ticker }
    return $r.instrument
  }
}
function Get-TiInstrumentByUid([string]$Uid) {
  # generic-инструмент по uid (валюты/металлы/что угодно) - для funding-продаж
  $r = Invoke-TInvest 'InstrumentsService' 'GetInstrumentBy' @{ idType = 'INSTRUMENT_ID_TYPE_UID'; id = $Uid }
  return $r.instrument
}
function Get-TiFuturesMargin([string]$Uid) {
  # initial_margin_on_buy/sell (MoneyValue), min_price_increment_amount (Quotation)
  return Invoke-TInvest 'InstrumentsService' 'GetFuturesMargin' @{ instrumentId = $Uid }
}
function Get-TiTradingSchedules([string]$Exchange, [string]$FromIso, [string]$ToIso) {
  return Invoke-TInvest 'InstrumentsService' 'TradingSchedules' @{ exchange = $Exchange; from = $FromIso; to = $ToIso }
}
function Get-TiTradingStatus([string]$Uid) {
  return Invoke-TInvest 'MarketDataService' 'GetTradingStatus' @{ instrumentId = $Uid }
}
# гейт пригодности инструмента (боевой нюанс №2): api_trade_available_flag + class_code
function Assert-Tradeable($info, [string]$Kind) {
  $wantClass = if ($Kind -eq 'fut') { 'SPBFUT' } else { 'TQBR' }
  if ([string]$info.class_code -ne $wantClass -and [string]$info.classCode -ne $wantClass) {
    throw "инструмент $($info.ticker): class_code '$($info.class_code)$($info.classCode)' != $wantClass"
  }
  $flag = $null
  if ($info.PSObject.Properties['api_trade_available_flag']) { $flag = $info.api_trade_available_flag }
  elseif ($info.PSObject.Properties['apiTradeAvailableFlag']) { $flag = $info.apiTradeAvailableFlag }
  if ($flag -ne $true) { throw "инструмент $($info.ticker): api_trade_available_flag != true (торговля через API недоступна)" }
  return $true
}

# ================= маркет-дата (минимум: история идёт из MOEX ISS, не отсюда) =================
function Get-TiLastPrices([string[]]$Uids) {
  $r = Invoke-TInvest 'MarketDataService' 'GetLastPrices' @{ instrumentId = @($Uids) }
  return @($r.lastPrices)
}
function Get-TiOrderBook([string]$Uid, [int]$Depth = 10) {
  return Invoke-TInvest 'MarketDataService' 'GetOrderBook' @{ instrumentId = $Uid; depth = $Depth }
}

# ================= счёт / портфель =================
function Get-TiAccounts { $r = Invoke-TInvest 'UsersService' 'GetAccounts' @{}; return @($r.accounts) }
function Get-TiMarginAttributes([string]$AccId) {
  # liquid_portfolio, starting_margin (использованное ГО), funds_sufficiency_level - VERIFY поля
  return Invoke-TInvest 'UsersService' 'GetMarginAttributes' @{ accountId = $AccId }
}
function Get-TiPortfolio([string]$AccId) {
  return Invoke-TInvest 'OperationsService' 'GetPortfolio' @{ accountId = $AccId; currency = 'RUB' }
}
function Get-TiPositions([string]$AccId) {
  return Invoke-TInvest 'OperationsService' 'GetPositions' @{ accountId = $AccId }
}
function Get-TiOperations([string]$AccId, [string]$FromIso, [string]$ToIso) {
  $r = Invoke-TInvest 'OperationsService' 'GetOperations' @{ accountId = $AccId; from = $FromIso; to = $ToIso; state = 'OPERATION_STATE_EXECUTED' }
  return @($r.operations)
}

# ================= ордера =================
# Клиентский идемпотентный ключ заявки. Боевой факт (песочница 2026-07-17): orderId ОБЯЗАН быть UUID
# («order id has invalid UUID format») -> детерминированный UUID из MD5("LRF-{intent}-{leg}"):
# повтор того же intent+leg даёт ТОТ ЖЕ UUID (идемпотентность сохранена), формат валиден.
function New-TiOrderKey([string]$IntentId, [string]$Leg) {
  $md5 = [Security.Cryptography.MD5]::Create()
  $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("LRF-$IntentId-$Leg"))
  return (New-Object Guid (,$bytes)).ToString()
}

function Post-TiMarketOrder([string]$AccId, [string]$Uid, [string]$Dir, [int]$Lots, [string]$OrderKey) {
  $body = @{ accountId = $AccId; instrumentId = $Uid; quantity = ([long]$Lots).ToString()
    direction = $(if ($Dir -eq 'buy') { 'ORDER_DIRECTION_BUY' } else { 'ORDER_DIRECTION_SELL' })
    orderType = 'ORDER_TYPE_MARKET'; orderId = $OrderKey }
  return Invoke-TInvest 'OrdersService' 'PostOrder' $body -Mutating
}
function Post-TiLimitOrder([string]$AccId, [string]$Uid, [string]$Dir, [int]$Lots, [decimal]$Px, [string]$OrderKey) {
  $body = @{ accountId = $AccId; instrumentId = $Uid; quantity = ([long]$Lots).ToString()
    direction = $(if ($Dir -eq 'buy') { 'ORDER_DIRECTION_BUY' } else { 'ORDER_DIRECTION_SELL' })
    orderType = 'ORDER_TYPE_LIMIT'; price = (D2Q $Px); orderId = $OrderKey }
  return Invoke-TInvest 'OrdersService' 'PostOrder' $body -Mutating
}
function Get-TiOrderState([string]$AccId, [string]$OrderId) {
  return Invoke-TInvest 'OrdersService' 'GetOrderState' @{ accountId = $AccId; orderId = $OrderId }
}
function Get-TiOrders([string]$AccId) {
  $r = Invoke-TInvest 'OrdersService' 'GetOrders' @{ accountId = $AccId }
  return @($r.orders)
}
function Cancel-TiOrder([string]$AccId, [string]$OrderId) {
  return Invoke-TInvest 'OrdersService' 'CancelOrder' @{ accountId = $AccId; orderId = $OrderId } -Mutating
}

# ================= стоп-ордера (хранятся у брокера, не на бирже: перевыставление =================
# не жжёт лимит транзакций Мосбиржи; в ПЕСОЧНИЦЕ StopOrders не поддерживаются - эмуляция движком)
# Type: 'stop_loss' (stop-market) | 'take_profit'. VERIFY: лимиты кол-ва, постановка вне сессии.
function Post-TiStopOrder([string]$AccId, [string]$Uid, [string]$Dir, [int]$Lots,
                          [decimal]$StopPx, [string]$Type = 'stop_loss', [string]$ExpIso = '') {
  $stopType = if ($Type -eq 'take_profit') { 'STOP_ORDER_TYPE_TAKE_PROFIT' } else { 'STOP_ORDER_TYPE_STOP_LOSS' }
  $body = @{ accountId = $AccId; instrumentId = $Uid; quantity = ([long]$Lots).ToString()
    direction = $(if ($Dir -eq 'buy') { 'STOP_ORDER_DIRECTION_BUY' } else { 'STOP_ORDER_DIRECTION_SELL' })
    stopPrice = (D2Q $StopPx); stopOrderType = $stopType
    expirationType = 'STOP_ORDER_EXPIRATION_TYPE_GOOD_TILL_CANCEL' }
  if ($ExpIso) { $body.expirationType = 'STOP_ORDER_EXPIRATION_TYPE_GOOD_TILL_DATE'; $body.expireDate = $ExpIso }
  return Invoke-TInvest 'StopOrdersService' 'PostStopOrder' $body -Mutating
}
function Get-TiStopOrders([string]$AccId) {
  $r = Invoke-TInvest 'StopOrdersService' 'GetStopOrders' @{ accountId = $AccId }
  return @($r.stopOrders)
}
function Cancel-TiStopOrder([string]$AccId, [string]$StopOrderId) {
  return Invoke-TInvest 'StopOrdersService' 'CancelStopOrder' @{ accountId = $AccId; stopOrderId = $StopOrderId } -Mutating
}

# ================= песочница (SandboxService; только при TINVEST_MODE=sandbox) =================
# ВАЖНО: по v2 песочница может жить и на отдельном хосте sandbox-invest-public-api.tinkoff.ru,
# и на общем invest-public-api.tinkoff.ru (различие - токен). Resolve-TiSandboxBase пробует
# песочный хост и при сетевой ошибке падает на общий.
function Resolve-TiSandboxBase {
  if ($script:TI.mode -ne 'sandbox') { return }
  try {
    $null = Invoke-TInvest 'SandboxService' 'GetSandboxAccounts' @{}
  } catch [System.Net.WebException] {
    $old = $script:TI.base
    $script:TI.base = 'https://invest-public-api.tinkoff.ru/rest'
    try { $null = Invoke-TInvest 'SandboxService' 'GetSandboxAccounts' @{} }
    catch { $script:TI.base = $old; throw "песочница недоступна ни на sandbox-хосте, ни на общем: $($_.Exception.Message)" }
  }
}
function Get-TiSandboxAccounts { $r = Invoke-TInvest 'SandboxService' 'GetSandboxAccounts' @{}; return @($r.accounts) }
function Open-TiSandboxAccount([string]$Name = 'rf-live-drill') {
  $r = Invoke-TInvest 'SandboxService' 'OpenSandboxAccount' @{ name = $Name }
  return [string]$r.accountId
}
function Close-TiSandboxAccount([string]$AccId) {
  return Invoke-TInvest 'SandboxService' 'CloseSandboxAccount' @{ accountId = $AccId }
}
function Invoke-TiSandboxPayIn([string]$AccId, [decimal]$Rub) {
  $r = Invoke-TInvest 'SandboxService' 'SandboxPayIn' @{ accountId = $AccId
    amount = @{ units = ([long][math]::Truncate($Rub)).ToString([Globalization.CultureInfo]::InvariantCulture)
      nano = 0; currency = 'rub' } }
  return $r
}

# ================= маппинг статусов заявки -> состояния state machine =================
# VERIFY точный набор строк статусов REST-gateway
function ConvertTo-TiOrderPhase([string]$ExecStatus) {
  switch -Wildcard ($ExecStatus) {
    '*PARTIALLYFILL*' { return 'PARTIAL' }   # проверять ДО '*_FILL' (PARTIALLYFILL тоже кончается на FILL)
    '*_FILL' { return 'FILLED' }             # EXECUTION_REPORT_STATUS_FILL
    '*REJECTED*' { return 'REJECTED' }
    '*CANCELLED*' { return 'CANCELLED' }
    '*NEW*' { return 'POSTED' }
    default { return 'POSTED' }
  }
}

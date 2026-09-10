# lib_alor.ps1 - минимальный клиент Alor OpenAPI: обмен refresh-токена на access + история свечей.
# Зачем: во время блокировки MOEX (инцидент 2026-09-10, биржа закрыла подсеть VPS целиком) нужен
# резервный источник для серии индекса IMOEX. T-Invest здесь не годится - индексы у него есть в
# Indicatives, но свечей по ним не отдаёт (0 баров), а подменять IMOEX на IMOEX2 нельзя: серия
# сверяется по SHA с бумажной, чужой индекс сломает кросс-контроль сигналов.
# Токен живёт в /etc/trading-live.env (ALOR_REFRESH_TOKEN), как и остальные секреты VPS.

$script:AlorAccess = ''

# Access-токен Alor живёт ~30 минут; тик - отдельный процесс на минуту, поэтому кэша в пределах
# процесса достаточно, продлевать нечего.
function Get-AlorAccessToken {
  if ($script:AlorAccess) { return $script:AlorAccess }
  $rt = [string]$env:ALOR_REFRESH_TOKEN
  if (-not $rt) { throw 'ALOR: не задан ALOR_REFRESH_TOKEN' }
  $u = 'https://oauth.alor.ru/refresh?token=' + [uri]::EscapeDataString($rt)
  $r = Invoke-RestMethod -Uri $u -Method Post -TimeoutSec 15
  $tok = [string]$r.AccessToken
  if (-not $tok) { throw 'ALOR: пустой AccessToken в ответе' }
  $script:AlorAccess = $tok
  return $tok
}

# Свечи Alor в контракте Get-IssCandles: {t,o,h,l,c,v,end}, t = MSK-как-UTC мс.
#
# Метка времени: Alor отдаёт unix-секунды на 00:00 торгового дня - это УЖЕ совпадает с конвенцией
# ISS, сдвиг на +3ч (как для T-Invest) здесь НЕ нужен. Проверено на боевых данных 2026-09-10:
# из 126 общих дней IMOEX 125 совпали с ISS до копейки (единственное расхождение - максимум
# 11.06 на 0.02 пункта при значении 2528, то есть 0.0008%).
#
# Выходные: Alor отдаёт фантомные бары с o=h=l=c за сб/вс, которых у ISS нет (в выборке таких
# оказалось 22, и все 22 - именно выходные). Их выбрасываем, иначе серия разойдётся с бумажной
# и собьётся детект первого торгового дня месяца у momentum-рукава. Фильтр намеренно требует
# ОБА признака (выходной И плоский бар), чтобы никогда не выкинуть настоящий будний бар.
function Get-AlorCandles([string]$Symbol, [int]$Interval, [long]$FromMs, [long]$ToMs, [string]$Exchange = 'MOEX') {
  $tf = switch ($Interval) { 24 { 'D' } 60 { '3600' } default { throw "ALOR: неизвестный интервал $Interval" } }
  $from = [long][math]::Floor($FromMs / 1000)
  $to = [long][math]::Ceiling($ToMs / 1000)
  $u = "https://api.alor.ru/md/v2/history?symbol=$Symbol&exchange=$Exchange&tf=$tf&from=$from&to=$to"
  $hdr = @{ Authorization = 'Bearer ' + (Get-AlorAccessToken) }
  $r = Invoke-RestMethod -Uri $u -Headers $hdr -TimeoutSec 15
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($b in @($r.history)) {
    if ($null -eq $b) { continue }
    $o = [double]$b.open; $h = [double]$b.high; $l = [double]$b.low; $c = [double]$b.close
    $ms = [long]$b.time * 1000L
    $dow = (MsToUtc $ms).DayOfWeek
    $flat = ($o -eq $h -and $h -eq $l -and $l -eq $c)
    if ($flat -and ($dow -eq [DayOfWeek]::Saturday -or $dow -eq [DayOfWeek]::Sunday)) { continue }
    $out.Add([pscustomobject]@{ t = $ms; o = $o; h = $h; l = $l; c = $c; v = [double]$b.volume; end = '' })
  }
  return ,$out.ToArray()
}

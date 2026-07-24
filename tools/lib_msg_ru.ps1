# lib_msg_ru.ps1 - человекочитаемые русские формулировки для Telegram-сообщений движков.
# Dot-source в live_engine.ps1 и live_rf_engine.ps1. Только форматирование текста -
# никакой торговой логики, ничего не бросает. Читает карту имён data/names_ru.json.
#
# Форматирование культуронезависимо (движки работают в InvariantCulture, а ru-RU ICU
# на VPS может отсутствовать): разряды - пробелом, десятичная - запятой, минус - обычный дефис.

function Get-RuNames([string]$Root) {
  # Карта тикер->русское имя. Нет файла/битый JSON -> $null (RuName сам сделает фолбэк).
  $p = Join-Path $Root 'data/names_ru.json'
  try { if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}
  return $null
}

function Cap([string]$s) {
  # Заглавная первая буква (для начала строки/предложения). Кириллица корректна и в Invariant.
  if (-not $s) { return $s }
  return $s.Substring(0, 1).ToUpper() + $s.Substring(1)
}

function RuName($Names, [string]$Cat, [string]$Ticker, [string]$Secid = '') {
  # 'crypto': 'LTC-USDT' -> "лайткоин (LTC)"; 'fut': 'BR' (+ секид 'BRQ6') -> "нефть Brent (BRQ6)".
  # Имя из карты в форме для середины предложения; caller зовёт Cap() для начала строки.
  $ru = ''
  if ($null -ne $Names -and $Names.PSObject.Properties[$Cat]) {
    $m = $Names.$Cat
    if ($m.PSObject.Properties[$Ticker]) { $ru = [string]$m.$Ticker }
  }
  if ($Cat -eq 'crypto') {
    $base = ($Ticker -split '-')[0]
    if (-not $ru) { $ru = $base }
    return "$ru ($base)"
  }
  if (-not $ru) { $ru = $Ticker }
  $tag = if ($Secid) { $Secid } else { $Ticker }
  return "$ru ($tag)"
}

function Fmt-Money([double]$v, [string]$Cur = '', [int]$Dec = 0, [switch]$Sign) {
  # "-18 749 ₽", "+1,36 $", "1 250,40 $". Знак "+" только при -Sign; минус - всегда.
  $neg = $v -lt 0
  $abs = [math]::Round([math]::Abs($v), $Dec)
  $s = $abs.ToString('F' + $Dec, [Globalization.CultureInfo]::InvariantCulture)
  $parts = $s.Split('.')
  $intDigits = $parts[0]
  $grouped = ''
  $c = 0
  for ($i = $intDigits.Length - 1; $i -ge 0; $i--) {
    $grouped = $intDigits[$i] + $grouped
    $c++
    if (($c % 3) -eq 0 -and $i -gt 0) { $grouped = ' ' + $grouped }
  }
  $body = if ($Dec -gt 0) { $grouped + ',' + $parts[1] } else { $grouped }
  $sgn = if ($neg) { '-' } elseif ($Sign) { '+' } else { '' }
  $suffix = if ($Cur) { ' ' + $Cur } else { '' }
  return "$sgn$body$suffix"
}

function Fmt-Pct([double]$v, [int]$Dec = 1) {
  # Всегда со знаком: "+1,0%", "-2,7%".
  $neg = $v -lt 0
  $abs = [math]::Round([math]::Abs($v), $Dec)
  $s = $abs.ToString('F' + $Dec, [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
  $sgn = if ($neg) { '-' } else { '+' }
  return "$sgn$s%"
}

function Plural([int]$n, [string]$one, [string]$few, [string]$many) {
  # "1 позиция", "2 позиции", "5 позиций".
  $a = [math]::Abs($n)
  $m10 = $a % 10; $m100 = $a % 100
  if ($m10 -eq 1 -and $m100 -ne 11) { return $one }
  if ($m10 -ge 2 -and $m10 -le 4 -and ($m100 -lt 10 -or $m100 -ge 20)) { return $few }
  return $many
}

function RuSide([string]$Side, [string]$Form = 'past') {
  # long/Buy/buy -> длинная сторона. Формы:
  #   past (безлично, с "6 лотов"/"20 монет"): куплено / продано
  #   noun (самостоятельная метка):            покупка (лонг) / продажа (шорт)
  $long = @('long', 'Buy', 'buy') -contains $Side
  if ($Form -eq 'noun') { if ($long) { return 'покупка (лонг)' } else { return 'продажа (шорт)' } }
  if ($long) { return 'куплено' } else { return 'продано' }
}

function Fmt-Px([double]$p) {
  # Цена: до 6 знаков, хвостовые нули убраны, десятичная - запятая. 88.99->"88,99", 0.7596->"0,7596".
  return $p.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
}

function Fmt-Qty([double]$q) {
  # Количество: до 6 знаков, хвостовые нули убраны, десятичная - запятая.
  return $q.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
}

function RuCoins([double]$q) {
  # Слово "монета" в нужной форме. Дробное количество -> родительный ед. ч. ("1,6 монеты").
  if ([math]::Abs($q - [math]::Round($q)) -lt 1e-9) { return (Plural ([int][math]::Round($q)) 'монета' 'монеты' 'монет') }
  return 'монеты'
}

function RuLots([int]$n) { return (Plural $n 'лот' 'лота' 'лотов') }

function Fmt-DdFromPeak([double]$Peak, [double]$Eq) {
  # Просадка от пика как "-6,2%" (или "0,0%" на пике). Всегда <= 0.
  if ($Peak -le 0) { return '0,0%' }
  $f = ($Peak - $Eq) / $Peak
  if ($f -le 0.0005) { return '0,0%' }
  return '-' + ([math]::Round($f * 100, 1)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',') + '%'
}

function RuDaysWord([int]$n) { return (Plural $n 'день' 'дня' 'дней') }
function RuHoldRu([double]$hours) {
  # "36 ч" при <48 ч, иначе "N дней".
  if ($hours -lt 48) { return ("{0} ч" -f [int][math]::Round($hours)) }
  $d = [int][math]::Round($hours / 24.0)
  return ("{0} {1}" -f $d, (RuDaysWord $d))
}

<#
  Telegram-бот: уведомления о возможных входах по чек-листу
  (Bjorgum Key Levels + дивергенция MACD 12/26/9 + ATR14).

  Запуск:
    .\bot.ps1 -Setup            один раз: сохранить chat_id (сначала нажмите Start у бота)
    .\bot.ps1 -Test             тестовое сообщение
    .\bot.ps1 -DryRun           проверка без отправки (печатает сигналы в консоль)
    .\bot.ps1 -History 100      какие сигналы бот прислал бы за последние 100 свечей каждого ТФ (без отправки;
                                зоны берутся текущие, поэтому это приблизительно)
    .\bot.ps1                   обычный прогон (его запускает планировщик каждые 5 минут)
#>
param(
    [switch]$Setup,
    [switch]$Test,
    [switch]$DryRun,
    [int]$Lookback = 0,
    [int]$History = 0
)
if ($History -gt 0) { $DryRun = [switch]$true }
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = $PSScriptRoot
$CfgPath = Join-Path $Root 'config.json'
$StatePath = Join-Path $Root 'state.json'
$LogPath = Join-Path $Root 'bot.log'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Log([string]$m) {
    $line = '{0} {1}' -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', $Inv), $m
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}
function Fmt([double]$x) { $x.ToString('#,##0.##', $Inv).Replace(',', ' ') }

$Cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Секреты: переменные окружения (GitHub Actions) -> secrets.json (локально)
$SecretsPath = Join-Path $Root 'secrets.json'
$Sec = [pscustomobject]@{ telegram_token = ''; chat_id = '' }
if (Test-Path $SecretsPath) {
    $f = Get-Content $SecretsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Sec.telegram_token = [string]$f.telegram_token; $Sec.chat_id = [string]$f.chat_id
}
if ($env:TELEGRAM_TOKEN) { $Sec.telegram_token = $env:TELEGRAM_TOKEN }
if ($env:TELEGRAM_CHAT_ID) { $Sec.chat_id = $env:TELEGRAM_CHAT_ID }

# ---------------- Telegram ----------------
function Token-Ok { return ([string]$Sec.telegram_token) -match '^\d+:[\w-]+$' }
function Tg([string]$method, $body) {
    $url = "https://api.telegram.org/bot$($Sec.telegram_token)/$method"
    $json = $body | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}
function Send([string]$text) {
    if ($DryRun) { Write-Host "----- [DRY RUN] -----`n$text`n"; return }
    [void](Tg 'sendMessage' @{ chat_id = "$($Sec.chat_id)"; text = $text; parse_mode = 'HTML'; disable_web_page_preview = $true })
}

if ($Setup) {
    if (-not (Token-Ok)) { Write-Host 'Сначала вставьте токен бота в secrets.json (поле telegram_token).'; exit 1 }
    $u = Invoke-RestMethod "https://api.telegram.org/bot$($Sec.telegram_token)/getUpdates"
    $chat = @($u.result | ForEach-Object { $_.message.chat } | Where-Object { $_ }) | Select-Object -Last 1
    if (-not $chat) { Write-Host 'Бот пока не получил сообщений. Откройте бота в Telegram, нажмите Start и запустите -Setup ещё раз.'; exit 1 }
    $Sec.chat_id = "$($chat.id)"
    ($Sec | ConvertTo-Json) | Set-Content -Path $SecretsPath -Encoding UTF8
    Send '✅ Бот подключён. Буду присылать возможные входы по вашему чек-листу.'
    Write-Host 'Готово: chat_id сохранён, тестовое сообщение отправлено.'
    exit 0
}
if ($Test) { Send '🔔 Тестовое сообщение от бота сетапов.'; Write-Host 'Отправлено.'; exit 0 }
if (-not $DryRun -and (-not (Token-Ok) -or -not $Sec.chat_id)) {
    Log 'Не настроены telegram_token / chat_id (secrets.json или TELEGRAM_TOKEN / TELEGRAM_CHAT_ID)'
    exit 1
}

# ---------------- Данные ----------------
$Span = @{ '5m' = [TimeSpan]::FromMinutes(5); '15m' = [TimeSpan]::FromMinutes(15); '30m' = [TimeSpan]::FromMinutes(30)
           '1h' = [TimeSpan]::FromHours(1); '4h' = [TimeSpan]::FromHours(4); '1d' = [TimeSpan]::FromDays(1) }
$TvInt = @{ '5m' = '5'; '15m' = '15'; '30m' = '30'; '1h' = '60'; '4h' = '240'; '1d' = 'D' }
$YRange = @{ '5m' = '5d'; '15m' = '30d'; '30m' = '30d'; '1h' = '200d'; '4h' = '300d'; '1d' = '5y' }
$Cache = @{}

function Get-Binance([string]$ticker, [string]$tf) {
    $base = if ($Cfg.binance_base) { $Cfg.binance_base } else { 'https://api.binance.com' }
    $raw = Invoke-RestMethod "$base/api/v3/klines?symbol=$ticker&interval=$tf&limit=1000" -UserAgent 'setup-alert-bot'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $raw) {
        $list.Add([pscustomobject]@{ t = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$k[0]).UtcDateTime
            o = [double]$k[1]; h = [double]$k[2]; l = [double]$k[3]; c = [double]$k[4] })
    }
    return ,$list
}
function Get-Yahoo([string]$ticker, [string]$tf) {
    $int = if ($tf -eq '1h' -or $tf -eq '4h') { '60m' } else { $tf }
    $url = 'https://query1.finance.yahoo.com/v8/finance/chart/{0}?interval={1}&range={2}' -f [uri]::EscapeDataString($ticker), $int, $YRange[$tf]
    $r = (Invoke-RestMethod $url -UserAgent 'Mozilla/5.0').chart.result[0]
    $q = $r.indicators.quote[0]; $ts = $r.timestamp
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ts.Count; $i++) {
        if ($null -eq $q.close[$i] -or $null -eq $q.high[$i] -or $null -eq $q.low[$i] -or $null -eq $q.open[$i]) { continue }
        $list.Add([pscustomobject]@{ t = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts[$i]).UtcDateTime
            o = [double]$q.open[$i]; h = [double]$q.high[$i]; l = [double]$q.low[$i]; c = [double]$q.close[$i] })
    }
    if ($tf -eq '4h') {
        $agg = New-Object System.Collections.Generic.List[object]; $cur = $null
        foreach ($b in $list) {
            $k = $b.t.Date.AddHours([Math]::Floor($b.t.Hour / 4) * 4)
            if ($cur -and $cur.t -eq $k) { $cur.h = [Math]::Max($cur.h, $b.h); $cur.l = [Math]::Min($cur.l, $b.l); $cur.c = $b.c }
            else { $cur = [pscustomobject]@{ t = $k; o = $b.o; h = $b.h; l = $b.l; c = $b.c }; $agg.Add($cur) }
        }
        $list = $agg
    }
    return ,$list
}
function Get-Bars($sym, [string]$tf) {
    $key = "$($sym.name)|$tf"
    if ($Cache.ContainsKey($key)) { return ,$Cache[$key] }
    $list = if ($sym.source -eq 'yahoo') { Get-Yahoo $sym.ticker $tf } else { Get-Binance $sym.ticker $tf }
    $now = [DateTime]::UtcNow
    # только закрытые свечи
    while ($list.Count -gt 0 -and $list[$list.Count - 1].t.Add($Span[$tf]) -gt $now) { $list.RemoveAt($list.Count - 1) }
    $arr = $list.ToArray()
    $Cache[$key] = $arr
    return ,$arr
}

# ---------------- Индикаторы ----------------
function Rma([double[]]$v, [int]$len) {
    $out = New-Object double[] $v.Count; $sum = 0.0
    for ($i = 0; $i -lt $v.Count; $i++) {
        if ($i -lt $len) { $sum += $v[$i]; $out[$i] = if ($i -eq $len - 1) { $sum / $len } else { [double]::NaN } }
        else { $out[$i] = ($out[$i - 1] * ($len - 1) + $v[$i]) / $len }
    }
    return ,$out
}
function Ema([double[]]$v, [int]$len) {
    $out = New-Object double[] $v.Count; $a = 2.0 / ($len + 1); $sum = 0.0
    for ($i = 0; $i -lt $v.Count; $i++) {
        if ($i -lt $len) { $sum += $v[$i]; $out[$i] = if ($i -eq $len - 1) { $sum / $len } else { [double]::NaN } }
        else { $out[$i] = $a * $v[$i] + (1 - $a) * $out[$i - 1] }
    }
    return ,$out
}
function Atr($bars, [int]$len) {
    $tr = New-Object double[] $bars.Count
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $b = $bars[$i]
        if ($i -eq 0) { $tr[$i] = $b.h - $b.l } else {
            $pc = $bars[$i - 1].c
            $tr[$i] = [Math]::Max($b.h - $b.l, [Math]::Max([Math]::Abs($b.h - $pc), [Math]::Abs($b.l - $pc))) }
    }
    return ,(Rma $tr $len)
}

# Порт Bjorgum Key Levels (настройки по умолчанию: 20/15, 4 пивота, ATR30 x0.5, макс 5%, HA, Align Zones)
function KeyLevels($bars) {
    $left = 20; $right = 15; $nPiv = 4
    $n = $bars.Count
    $atr = Atr $bars 30
    $haO = New-Object double[] $n; $haC = New-Object double[] $n
    $sH = New-Object double[] $n; $sL = New-Object double[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $b = $bars[$i]; $haC[$i] = ($b.o + $b.h + $b.l + $b.c) / 4
        $haO[$i] = if ($i -eq 0) { ($b.o + $b.c) / 2 } else { ($haO[$i - 1] + $haC[$i - 1]) / 2 }
        $sH[$i] = [Math]::Max($haO[$i], $haC[$i]); $sL[$i] = [Math]::Min($haO[$i], $haC[$i])
    }
    $highs = New-Object System.Collections.ArrayList; $lows = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $nPiv; $k++) { [void]$highs.Add($null); [void]$lows.Add($null) }
    $align = {
        param($x, $y)
        if ($null -eq $y[0]) { return }
        for ($i = 0; $i -lt $x.Count; $i++) {
            if ($null -eq $x[$i]) { continue }
            $T = $y[0].top; $B = $y[0].bot; $t = $x[$i].top; $bb = $x[$i].bot
            if (($T -gt $bb -and $T -lt $t) -or ($B -lt $t -and $B -gt $bb) -or ($T -gt $t -and $B -lt $bb) -or ($B -gt $bb -and $T -lt $t)) {
                $y[0].top = $t; $y[0].bot = $bb
            }
        }
    }
    for ($i = 0; $i -lt $n; $i++) {
        $c = $bars[$i].c
        $p = $i - $right
        if ($p -ge $left -and -not [double]::IsNaN($atr[$p])) {
            $band = [Math]::Min($atr[$p] * 0.5, $bars[$p].c * 0.05) / 2
            $isH = $true; $isL = $true
            for ($j = $p - $left; $j -le $p + $right; $j++) {
                if ($j -eq $p) { continue }
                if ($j -lt $p) { if ($sH[$j] -ge $sH[$p]) { $isH = $false }; if ($sL[$j] -le $sL[$p]) { $isL = $false } }
                else { if ($sH[$j] -gt $sH[$p]) { $isH = $false }; if ($sL[$j] -lt $sL[$p]) { $isL = $false } }
            }
            if ($isH) { $highs.Insert(0, [pscustomobject]@{ top = $sH[$p] + $band; bot = $sH[$p] - $band; bull = $false }); $highs.RemoveAt($highs.Count - 1) }
            if ($isL) { $lows.Insert(0, [pscustomobject]@{ top = $sL[$p] + $band; bot = $sL[$p] - $band; bull = $true }); $lows.RemoveAt($lows.Count - 1) }
        }
        & $align $highs $highs; & $align $highs $lows; & $align $lows $lows; & $align $lows $highs
        foreach ($z in @($highs) + @($lows)) {
            if ($null -eq $z) { continue }
            if ($c -gt $z.top -and -not $z.bull) { $z.bull = $true }
            if ($c -lt $z.bot -and $z.bull) { $z.bull = $false }
        }
    }
    return @(@($highs) + @($lows) | Where-Object { $_ })
}

# ---------------- Дивергенция MACD (по линии) ----------------
function Find-Div($bars, [string]$tf, [int]$fresh) {
    $n = $bars.Count
    $L = [int]$Cfg.pivot_left; $R = [int]$Cfg.pivot_right; $gap = [int]$Cfg.max_swing_gap
    $closes = New-Object double[] $n
    for ($i = 0; $i -lt $n; $i++) { $closes[$i] = $bars[$i].c }
    $f = Ema $closes 12; $s = Ema $closes 26
    $macd = New-Object double[] $n
    for ($i = 0; $i -lt $n; $i++) { $macd[$i] = $f[$i] - $s[$i] }
    $atr = Atr $bars ([int]$Cfg.atr_length)
    $pl = New-Object System.Collections.Generic.List[int]; $ph = New-Object System.Collections.Generic.List[int]
    $start = [Math]::Max([Math]::Max($L, 40), $n - $gap - $fresh - 40)
    for ($p = $start; $p -le $n - 1 - $R; $p++) {
        $isL = $true; $isH = $true
        for ($j = $p - $L; $j -le $p + $R; $j++) {
            if ($j -eq $p) { continue }
            if ($bars[$j].l -le $bars[$p].l) { $isL = $false }
            if ($bars[$j].h -ge $bars[$p].h) { $isH = $false }
        }
        if ($isL) { $pl.Add($p) }; if ($isH) { $ph.Add($p) }
    }
    $sigs = @()
    foreach ($side in 'long', 'short') {
        $pv = if ($side -eq 'long') { $pl } else { $ph }
        if ($pv.Count -lt 2) { continue }
        $b = $pv[$pv.Count - 1]; $a = $pv[$pv.Count - 2]
        if (($n - 1 - $b) -gt ($R + $fresh) -or ($b - $a) -gt $gap) { continue }
        $type = $null
        if ($side -eq 'long') {
            $xa = $bars[$a].l; $xb = $bars[$b].l
            if ($xb -lt $xa -and $macd[$b] -gt $macd[$a]) { $type = 'regular' }
            elseif ($xb -gt $xa -and $macd[$b] -lt $macd[$a]) { $type = 'hidden' }
        } else {
            $xa = $bars[$a].h; $xb = $bars[$b].h
            if ($xb -gt $xa -and $macd[$b] -lt $macd[$a]) { $type = 'regular' }
            elseif ($xb -lt $xa -and $macd[$b] -gt $macd[$a]) { $type = 'hidden' }
        }
        if (-not $type -or -not ($Cfg.divergence_types -contains $type)) { continue }
        $ci = [Math]::Min($b + $R, $n - 1)   # свеча, на которой дивергенция подтвердилась
        $sigs += [pscustomobject]@{ side = $side; type = $type; tf = $tf
            ta = $bars[$a].t; tb = $bars[$b].t; xa = $xa; xb = $xb; ma = $macd[$a]; mb = $macd[$b]
            entry = $bars[$ci].c; atr = $atr[$ci]; tc = $bars[$ci].t }
    }
    return ,$sigs
}

# ---------------- Стоп / тейк по правилам ----------------
$Prio = @{ '1d' = 5; '4h' = 4; '1h' = 3; '30m' = 2; '15m' = 1; '5m' = 0 }
function Build-Plan($sig, $zones) {
    $e = $sig.entry; $atr = $sig.atr; $buf = [double]$Cfg.zone_buffer_atr * $atr
    $z = $null; $sl = $null; $tp = $null
    if ($sig.side -eq 'long') {
        $z = $zones | Where-Object { $_.bull -and $sig.xb -le $_.top -and $sig.xb -ge ($_.bot - $buf) } |
            Sort-Object @{ e = { $Prio[$_.tf] }; Descending = $true }, @{ e = { $_.top }; Descending = $true } | Select-Object -First 1
        if ($z) {
            $sl = $z.bot - $buf
            $tp = ($zones | Where-Object { $_.bot -gt $e } | Measure-Object -Property bot -Minimum).Minimum
        } else { $sl = $e - [double]$Cfg.no_zone_sl_atr * $atr; $tp = $e + [double]$Cfg.no_zone_tp_atr * $atr }
        $risk = $e - $sl; $reward = if ($null -ne $tp) { $tp - $e } else { $null }
    } else {
        $z = $zones | Where-Object { -not $_.bull -and $sig.xb -ge $_.bot -and $sig.xb -le ($_.top + $buf) } |
            Sort-Object @{ e = { $Prio[$_.tf] }; Descending = $true }, @{ e = { $_.bot }; Descending = $false } | Select-Object -First 1
        if ($z) {
            $sl = $z.top + $buf
            $tp = ($zones | Where-Object { $_.top -lt $e } | Measure-Object -Property top -Maximum).Maximum
        } else { $sl = $e + [double]$Cfg.no_zone_sl_atr * $atr; $tp = $e - [double]$Cfg.no_zone_tp_atr * $atr }
        $risk = $sl - $e; $reward = if ($null -ne $tp) { $e - $tp } else { $null }
    }
    $plan = [pscustomobject]@{ ok = $false; reason = ''; zone = $z; sl = $sl; tp = $tp; risk = $risk; reward = $reward; rr = 0.0 }
    if ($risk -le 0) { $plan.reason = 'цена уже за стопом'; return $plan }
    if ($null -eq $tp -or $reward -le 0) { $plan.reason = 'нет следующей зоны для цели'; return $plan }
    $plan.rr = $reward / $risk
    if ($plan.rr -lt ([double]$Cfg.min_rr - 1e-9)) { $plan.reason = ('R:R 1:{0} < 1:{1}' -f $plan.rr.ToString('0.0', $Inv), $Cfg.min_rr); return $plan }
    $plan.ok = $true
    return $plan
}

function Format-Msg($sym, $sig, $plan) {
    $long = $sig.side -eq 'long'
    $dir = if ($long) { '🟢 ЛОНГ' } else { '🔴 ШОРТ' }
    $kind = if ($sig.type -eq 'regular') { 'классическая' } else { 'скрытая' }
    $bb = if ($long) { 'бычья' } else { 'медвежья' }
    $ext = if ($long) { 'минимумы' } else { 'максимумы' }
    $tv = ('https://www.tradingview.com/chart/?symbol={0}&interval={1}' -f [uri]::EscapeDataString($sym.tv), $TvInt[$sig.tf]).Replace('&', '&amp;')
    if ($plan.zone) {
        $role = if ($plan.zone.bull) { 'поддержка' } else { 'сопротивление' }
        $zoneLine = 'Зона: {0} {1}  {2} – {3}' -f $role, $plan.zone.tf.ToUpper(), (Fmt $plan.zone.bot), (Fmt $plan.zone.top)
    } else { $zoneLine = 'Зоны рядом нет → SL/TP по ATR' }
    $lines = @(
        "<b>$dir · $($sym.name) · $($sig.tf)</b>"
        "Дивергенция MACD: $kind $bb"
        ('Цена ({0}): {1} → {2}' -f $ext, (Fmt $sig.xa), (Fmt $sig.xb))
        ('MACD: {0} → {1}' -f (Fmt $sig.ma), (Fmt $sig.mb))
        $zoneLine
        ''
        ('Вход ≈ <b>{0}</b>  (закрытие {1} UTC)' -f (Fmt $sig.entry), $sig.tc.ToString('dd.MM HH:mm', $Inv))
        ('SL: {0}  (−{1})' -f (Fmt $plan.sl), (Fmt $plan.risk))
        ('TP: {0}  (+{1})' -f (Fmt $plan.tp), (Fmt $plan.reward))
        ('R:R = 1 : {0}' -f $plan.rr.ToString('0.0', $Inv))
        ('ATR{0} ({1}) = {2}' -f $Cfg.atr_length, $sig.tf, (Fmt $sig.atr))
        "<a href=`"$tv`">Открыть график</a>"
        '<i>Сигнал по вашим правилам, не рекомендация. Проверьте график перед входом.</i>'
    )
    return ($lines -join "`n")
}

# ---------------- Основной прогон ----------------
function To-Utc($v) {
    if ($v -is [DateTime]) { return $v.ToUniversalTime() }
    return [DateTime]::Parse([string]$v, $Inv, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
$State = @{}   # уже обработанные сигналы
$Meta = [ordered]@{ paused = $false; offset = [int64]0; commands_set = $false; sent_times = @() }
if (Test-Path $StatePath) {
    $raw = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($raw) {
        $sigObj = if ($raw.PSObject.Properties['signals']) { $raw.signals } else { $raw }
        if ($sigObj) { $sigObj.PSObject.Properties | ForEach-Object { if ($_.Name -ne 'meta') { $State[$_.Name] = To-Utc $_.Value } } }
        if ($raw.PSObject.Properties['meta'] -and $raw.meta) {
            $m = $raw.meta
            $Meta.paused = [bool]$m.paused; $Meta.offset = [int64]$m.offset; $Meta.commands_set = [bool]$m.commands_set
            $Meta.sent_times = @(@($m.sent_times) | Where-Object { $_ } | ForEach-Object { To-Utc $_ })
        }
    }
}

# ---------------- Команды из Telegram ----------------
function Status-Text {
    $now = [DateTime]::UtcNow
    $n24 = @($Meta.sent_times | Where-Object { $_ -gt $now.AddDays(-1) }).Count
    $st = if ($Meta.paused) { '⏸ на паузе' } else { '▶️ работает' }
    $where = if ($env:GITHUB_ACTIONS) { 'GitHub Actions (облако)' } else { 'этот компьютер' }
    $lines = @(
        "<b>Статус:</b> $st"
        ('Проверка: {0} UTC, дальше каждые ~5 мин' -f $now.ToString('dd.MM HH:mm', $Inv))
        "Где работает: $where"
        "Сигналов за 24 ч: $n24"
        ('Инструменты: {0}' -f ((@($Cfg.symbols) | ForEach-Object { $_.name }) -join ', '))
        ('Дивергенция: {0} · Зоны: {1}' -f ($Cfg.divergence_timeframes -join '/'), ($Cfg.zone_timeframes -join '/'))
    )
    return ($lines -join "`n")
}
function Handle-Commands {
    if ($DryRun) { return }
    if (-not $Meta.commands_set) {
        try {
            [void](Tg 'setMyCommands' @{ commands = @(
                @{ command = 'start'; description = 'Включить сигналы' }
                @{ command = 'stop'; description = 'Поставить сигналы на паузу' }
                @{ command = 'status'; description = 'Состояние бота' }) })
            $Meta.commands_set = $true
        } catch { Log "setMyCommands: $($_.Exception.Message)" }
    }
    $u = Tg 'getUpdates' @{ offset = [int64]$Meta.offset + 1; timeout = 0; allowed_updates = @('message') }
    foreach ($upd in @($u.result)) {
        if (-not $upd) { continue }
        $Meta.offset = [int64]$upd.update_id
        $msg = $upd.message
        if (-not $msg -or "$($msg.chat.id)" -ne "$($Sec.chat_id)") { continue }   # только ваш чат
        $cmd = ([string]$msg.text).Trim().Split(' ')[0].Split('@')[0].ToLower()
        switch ($cmd) {
            '/start'  { $Meta.paused = $false; Send '▶️ Сигналы включены. Проверка каждые ~5 минут.'; Log 'CMD start' }
            '/stop'   { $Meta.paused = $true;  Send '⏸ Сигналы на паузе. Чтобы включить снова, отправьте /start.'; Log 'CMD stop' }
            '/status' { Send (Status-Text); Log 'CMD status' }
            default   { Send "Команды:`n/start - включить сигналы`n/stop - пауза`n/status - состояние" }
        }
    }
}
try { Handle-Commands } catch { Log "ERROR commands: $($_.Exception.Message)" }
# Сколько свечей после подтверждения сигнал считается свежим (GitHub запускает с задержкой)
function Fresh-Bars([string]$tf) {
    if ($Lookback -gt 0) { return $Lookback }
    $m = if ($Cfg.fresh_minutes) { [double]$Cfg.fresh_minutes } else { 10 }
    return [int][Math]::Max(1, [Math]::Ceiling($m / $Span[$tf].TotalMinutes))
}
$sent = 0
$symbols = if ($Meta.paused -and -not $DryRun) { Log 'paused - analysis skipped'; @() } else { @($Cfg.symbols) }

foreach ($sym in $symbols) {
    try {
        $zones = New-Object System.Collections.Generic.List[object]
        foreach ($tf in $Cfg.zone_timeframes) {
            $bars = Get-Bars $sym $tf
            foreach ($z in (KeyLevels $bars)) { $z | Add-Member -NotePropertyName tf -NotePropertyValue $tf; $zones.Add($z) }
        }
        foreach ($tf in $Cfg.divergence_timeframes) {
            $bars = Get-Bars $sym $tf
            $found = @()
            if ($History -gt 0) {
                # прогон по истории: как если бы бот работал на каждой из последних N свечей
                for ($cut = [Math]::Max(100, $bars.Count - $History); $cut -le $bars.Count; $cut++) {
                    $found += Find-Div ($bars[0..($cut - 1)]) $tf 0
                }
            } else { $found = Find-Div $bars $tf (Fresh-Bars $tf) }
            $seen = @{}
            foreach ($sig in $found) {
                $sk = "$($sig.side)|$($sig.type)|$($sig.tb.Ticks)"; if ($seen.ContainsKey($sk)) { continue }; $seen[$sk] = 1
                $key = '{0}|{1}|{2}|{3}|{4}' -f $sym.name, $tf, $sig.side, $sig.type, $sig.tb.ToString('o', $Inv)
                if (-not $DryRun -and $State.ContainsKey($key)) { continue }
                $plan = Build-Plan $sig $zones
                if ($plan.ok) { Send (Format-Msg $sym $sig $plan); $sent++; $Meta.sent_times += [DateTime]::UtcNow; Log "SENT $key" }
                else { Log "SKIP $key : $($plan.reason)" }
                $State[$key] = [DateTime]::UtcNow
            }
        }
    } catch {
        Log "ERROR $($sym.name): $($_.Exception.Message)"
    }
}

if (-not $DryRun) {
    $cut = [DateTime]::UtcNow.AddDays(-7)
    $out = [ordered]@{}
    foreach ($k in $State.Keys) { if ($State[$k] -gt $cut) { $out[$k] = $State[$k].ToString('o', $Inv) } }
    $meta = [ordered]@{
        paused = [bool]$Meta.paused; offset = [int64]$Meta.offset; commands_set = [bool]$Meta.commands_set
        sent_times = @(@($Meta.sent_times) | Where-Object { $_ -gt $cut } | ForEach-Object { $_.ToString('o', $Inv) })
    }
    ([ordered]@{ signals = $out; meta = $meta } | ConvertTo-Json -Depth 5) | Set-Content -Path $StatePath -Encoding UTF8
}
Log "run done, sent=$sent"

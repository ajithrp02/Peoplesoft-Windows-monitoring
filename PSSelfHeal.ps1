<#
 PeopleSoft Self-Healing Agent (Windows / PowerShell 5.1+)

 Plan per server, every run:
   all services Running                      -> HEALTHY (summary email only)
   service(s) DOWN, CPU < cpuTrigger         -> PATH "start": email alert -> start down services (2 tries each) -> email result
   service(s) DOWN, CPU >= cpuTrigger        -> PATH "full" : email alert -> stop all (reverse) -> clear cache -> start all (2 tries each) -> email result
 Failure after retries -> email + ticket for a human.
 Safety: cooldown after a failed attempt, daily caps, maintenance windows, cache-path guard, -DryRun.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun          # log what would happen, change nothing
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config.json' }
$cfg     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$rem     = $cfg.remediation
$runTime = Get-Date
$runId   = $runTime.ToString('yyyyMMdd-HHmmss')
$dirs    = @{ State = "$root\state"; Logs = "$root\logs" }
$dirs.Values | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
Start-Transcript -Path "$($dirs.Logs)\selfheal-$runId.log" | Out-Null

if (-not $rem -or -not $rem.enabled) { Write-Host 'Remediation disabled in config.json (remediation.enabled = false).'; Stop-Transcript | Out-Null; return }

# ---------- Settings with defaults ----------
$cpuTrigger  = if ($rem.cpuTrigger)          { [double]$rem.cpuTrigger }          else { [double]$cfg.thresholds.cpuFail }
$cooldownMin = if ($rem.cooldownMinutes)     { [int]$rem.cooldownMinutes }        else { 30 }
$maxFull     = if ($rem.maxAttemptsPerDay)   { [int]$rem.maxAttemptsPerDay }      else { 2 }   # full restarts / 24h
$maxStart    = if ($rem.maxStartsPerDay)     { [int]$rem.maxStartsPerDay }        else { 6 }   # simple starts / 24h
$retries     = if ($rem.startRetries)        { [int]$rem.startRetries }           else { 2 }   # tries per service
$retryWait   = if ($rem.retryWaitSec)        { [int]$rem.retryWaitSec }           else { 15 }
$stopTimeout = if ($rem.stopTimeoutSec)      { [int]$rem.stopTimeoutSec }         else { 120 }
$startTimeout= if ($rem.startTimeoutSec)     { [int]$rem.startTimeoutSec }        else { 180 }
$dry         = [bool]$DryRun -or [bool]$rem.dryRun

# ---------- State ----------
$stPath = "$($dirs.State)\selfheal-state.json"
$hist = @()
if (Test-Path $stPath) { $hist = @((Get-Content $stPath -Raw | ConvertFrom-Json).attempts) | Where-Object { $_ } }
$hist = @($hist | Where-Object { [datetime]$_.time -gt $runTime.AddHours(-24) })

# ---------- Runs ON the target server (local or WinRM). mode = detect | start | full ----------
$agent = {
    param($srv, $rem, $cpuTrigger, $stopTimeout, $startTimeout, $dry, $mode, $retries, $retryWait)
    $log = New-Object System.Collections.ArrayList
    function L($m) { [void]$log.Add("$(Get-Date -Format 'HH:mm:ss')  $m") }

    function Resolve-Services($patterns) {
        $all = @(Get-CimInstance Win32_Service)
        foreach ($p in @($patterns)) {
            $p = ([string]$p).Trim(); if (-not $p) { continue }
            $all | Where-Object { $_.Name -like $p -or $_.DisplayName -like $p } | Select-Object -First 1
        }
    }
    function Get-Cpu {
        [math]::Round(((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5).CounterSamples |
            Measure-Object CookedValue -Average).Average, 1)
    }
    function Stop-Hung($name) {   # kill the process of a service stuck in a *Pending state
        $pidv = (Get-CimInstance Win32_Service -Filter "Name='$name'").ProcessId
        if ($pidv -gt 0) { L "  Killing PID $pidv ($name)"; Stop-Process -Id $pidv -Force -ErrorAction SilentlyContinue; Start-Sleep 3 }
    }
    # Start one service with retries. Returns $true when Running.
    function Start-Svc($s) {
        for ($i = 1; $i -le $retries; $i++) {
            $st = (Get-Service -Name $s.Name).Status
            if ($st -eq 'Running') { L "  $($s.DisplayName): Running"; return $true }
            L "Starting $($s.DisplayName) ($($s.Name)) - attempt $i of $retries (state: $st)"
            if ($dry) { return $true }
            try {
                if ($st -in 'StartPending','StopPending') { Stop-Hung $s.Name }
                Start-Service -Name $s.Name -ErrorAction Stop
                (Get-Service -Name $s.Name).WaitForStatus('Running', [timespan]::FromSeconds($startTimeout))
            } catch { L "  Attempt $i failed: $($_.Exception.Message)" }
            if ((Get-Service -Name $s.Name).Status -eq 'Running') { L "  Started OK on attempt $i"; return $true }
            if ($i -lt $retries) { Start-Sleep -Seconds $retryWait }
        }
        L "  FAILED to start $($s.DisplayName) after $retries attempts"
        return $false
    }

    $res = [ordered]@{ Plan = 'none'; Success = $false; Cpu = 0; Down = @(); Services = @(); Log = $log; Reason = '' }

    # ---- Detect ----
    $svc  = @(Resolve-Services $srv.services)
    $down = @($svc | Where-Object { $_.State -ne 'Running' })
    $cpu  = Get-Cpu
    $res.Cpu = $cpu; $res.Down = @($down | ForEach-Object { $_.DisplayName })
    $res.Services = @($svc | ForEach-Object { "$($_.DisplayName) [$($_.Name)]: $($_.State)" })
    foreach ($pat in @($srv.services)) {
        $pat = ([string]$pat).Trim()
        if ($pat -and -not (@($svc | Where-Object { $_.Name -like $pat -or $_.DisplayName -like $pat }))) { $res.Services += "NOT FOUND on server: $pat"; L "WARNING: service pattern not found: $pat" }
    }
    L "Check: services down = $($down.Count) of $($svc.Count); CPU = $cpu% (full-restart trigger >= $cpuTrigger%)"

    if ($down.Count -eq 0) { $res.Reason = 'All services running'; $res.Success = $true; return [pscustomobject]$res }
    $res.Plan = if ($cpu -ge $cpuTrigger) { 'full' } else { 'start' }
    if ($mode -eq 'detect') { $res.Reason = "Down: $($res.Down -join '; ') -> plan: $($res.Plan)"; return [pscustomobject]$res }
    $res.Plan = $mode   # act exactly as announced in the alert email

    # ---- PATH start: only start what is down, in configured order ----
    if ($mode -eq 'start') {
        $allOk = $true
        foreach ($s in $svc) {
            if ((Get-Service -Name $s.Name).Status -eq 'Running') { continue }
            if (-not (Start-Svc $s)) { $allOk = $false; break }   # later services depend on earlier ones
            Start-Sleep -Seconds $(if ($rem.startDelaySec) { [int]$rem.startDelaySec } else { 10 })
        }
        if ($dry) { $res.Reason = 'DRY RUN - no changes made'; $res.Success = $true; return [pscustomobject]$res }
        $res.Services = @($svc | ForEach-Object { "$($_.DisplayName) [$($_.Name)]: $((Get-Service -Name $_.Name).Status)" })
        $res.Success = $allOk -and -not (@($svc | Where-Object { (Get-Service -Name $_.Name).Status -ne 'Running' }))
        $res.Reason  = if ($res.Success) { 'Down service(s) started automatically' } else { "Could not start all services after $retries attempts" }
        return [pscustomobject]$res
    }

    # ---- PATH full: stop (reverse) -> clear cache -> start (order) ----
    $ordered = @($svc); [array]::Reverse($ordered)
    $protect = @(Resolve-Services $srv.noStopServices | ForEach-Object { $_.Name })
    foreach ($s in $ordered) {
        if ($s.Name -in $protect) { L "Protected (not stopped): $($s.DisplayName)"; continue }
        $cur = Get-Service -Name $s.Name
        if ($cur.Status -eq 'Stopped') { L "Already stopped: $($s.DisplayName)"; continue }
        L "Stopping: $($s.DisplayName) ($($s.Name))"
        if ($dry) { continue }
        try {
            Stop-Service -Name $s.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue
            $cur.WaitForStatus('Stopped', [timespan]::FromSeconds($stopTimeout))
        } catch {
            L "  Stop timed out/failed: $($_.Exception.Message)"
            if ($rem.killOnStopTimeout) { Stop-Hung $s.Name }
        }
        if ((Get-Service -Name $s.Name).Status -ne 'Stopped') { L "  ABORT: $($s.Name) will not stop"; $res.Reason = "Could not stop $($s.Name)"; return [pscustomobject]$res }
    }
    foreach ($path in @($srv.cachePaths)) {
        if (-not $path) { continue }
        if ($path.Length -lt 12 -or (Split-Path $path -Leaf) -notmatch 'cache') { L "SKIP unsafe cache path: $path"; continue }
        if (-not (Test-Path $path)) { L "Cache path not found: $path"; continue }
        L "Clearing cache: $path ($(@(Get-ChildItem $path -Force -ErrorAction SilentlyContinue).Count) items)"
        if ($dry) { continue }
        try { Get-ChildItem $path -Force | Remove-Item -Recurse -Force -ErrorAction Stop } catch { L "  Cache clear error: $($_.Exception.Message)" }
    }
    $allOk = $true
    foreach ($s in $svc) {
        if (-not (Start-Svc $s)) { $allOk = $false; break }
        if (-not $dry) { Start-Sleep -Seconds $(if ($rem.startDelaySec) { [int]$rem.startDelaySec } else { 10 }) }
    }
    if ($dry) { $res.Reason = 'DRY RUN - no changes made'; $res.Success = $true; return [pscustomobject]$res }
    Start-Sleep -Seconds 20
    $cpu2 = Get-Cpu; $res.Cpu = $cpu2
    $res.Services = @($svc | ForEach-Object { "$($_.DisplayName) [$($_.Name)]: $((Get-Service -Name $_.Name).Status)" })
    $stillDown = @($svc | Where-Object { (Get-Service -Name $_.Name).Status -ne 'Running' })
    L "Post-check: services still down = $($stillDown.Count); CPU = $cpu2%"
    $res.Success = ($allOk -and $stillDown.Count -eq 0 -and $cpu2 -lt $cpuTrigger)
    $res.Reason  = if ($res.Success) { 'Recovered: services restarted and cache cleared' } else { 'Restart done but services/CPU still unhealthy (or a service failed to start)' }
    [pscustomobject]$res
}

# ---------- Helpers ----------
function Send-Notice($subject, $bodyHtml) {
    if (-not $cfg.email.enabled) { return }
    $mail = @{
        SmtpServer = $cfg.email.smtp; Port = $(if ($cfg.email.port) { [int]$cfg.email.port } else { 25 })
        From = $cfg.email.from; To = @($cfg.email.to); Subject = $subject; Body = $bodyHtml; BodyAsHtml = $true
    }
    if ($cfg.email.useSsl) { $mail.UseSsl = $true }
    if ($env:SMTP_USER -and $env:SMTP_PASS) {
        $mail.Credential = New-Object Management.Automation.PSCredential($env:SMTP_USER, (ConvertTo-SecureString $env:SMTP_PASS -AsPlainText -Force))
    }
    try { Send-MailMessage @mail -ErrorAction Stop; Write-Host "Email sent: $subject" } catch { Write-Warning "Email failed: $($_.Exception.Message)" }
}
function New-Incident($short, $desc, $urgency) {
    if (-not $cfg.ticketing.enabled) {
        [pscustomobject]@{ Time = $runTime; Short = $short; Detail = $desc } | Export-Csv "$($dirs.State)\tickets-pending.csv" -Append -NoTypeInformation
        return 'PENDING'
    }
    try {
        $cred = New-Object Management.Automation.PSCredential($env:SN_USER, (ConvertTo-SecureString $env:SN_PASS -AsPlainText -Force))
        $body = @{ short_description = $short; description = $desc; urgency = $urgency; category = 'Monitoring'; assignment_group = $cfg.ticketing.assignmentGroup } | ConvertTo-Json
        (Invoke-RestMethod -Uri "$($cfg.ticketing.instanceUrl)/api/now/table/incident" -Method Post -Credential $cred -ContentType 'application/json' -Body $body).result.number
    } catch { Write-Warning "Ticket creation failed: $($_.Exception.Message)"; 'FAILED' }
}
function Test-Tcp($HostName, $Port, $TimeoutMs = 3000) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($HostName, $Port, $null, $null); return ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) }
    catch { return $false } finally { $c.Close() }
}
function Invoke-Agent($srv, $isLocal, $mode) {
    $argsList = @($srv, $rem, $cpuTrigger, $stopTimeout, $startTimeout, $dry, $mode, $retries, $retryWait)
    if ($isLocal) { & $agent @argsList } else { Invoke-Command -ComputerName $srv.name -ScriptBlock $agent -ArgumentList $argsList }
}
function Enc($t) { [System.Net.WebUtility]::HtmlEncode([string]$t) }

# ---------- Main loop ----------
$summary = New-Object System.Collections.Generic.List[object]
foreach ($srv in $cfg.servers) {
    if ($srv.PSObject.Properties.Name -contains 'autoHeal' -and -not $srv.autoHeal) { Write-Host "[$($srv.name)] autoHeal=false, skipping"; continue }
    $isLocal = $srv.name -in @($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1')

    # 1. Detect (read-only)
    try { $d = Invoke-Agent $srv $isLocal 'detect' }
    catch {
        Write-Warning "[$($srv.name)] agent failed: $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{ Server = $srv.name; Outcome = 'ERROR'; Reason = $_.Exception.Message; Cpu = ''; Services = @(); Detail = ''; Ticket = '' })
        continue
    }
    $d.Log | ForEach-Object { Write-Host "[$($srv.name)] $_" }
    if ($d.Plan -eq 'none') {
        $summary.Add([pscustomobject]@{ Server = $srv.name; Outcome = 'HEALTHY'; Reason = $d.Reason; Cpu = $d.Cpu; Services = $d.Services; Detail = ($d.Log -join "`n"); Ticket = '' })
        continue
    }
    $plan = $d.Plan

    # 2. Guard rails
    $mine = @($hist | Where-Object { $_.server -eq $srv.name -and $_.kind -eq $plan })
    $last = $mine | Sort-Object { [datetime]$_.time } -Descending | Select-Object -First 1
    $cap  = if ($plan -eq 'full') { $maxFull } else { $maxStart }
    $allow = $true; $why = ''
    if ($last -and -not $last.success -and ([datetime]$last.time) -gt $runTime.AddMinutes(-$cooldownMin)) { $allow = $false; $why = "last $plan attempt failed at $($last.time); cooling down $cooldownMin min" }
    elseif ($plan -eq 'full' -and $last -and ([datetime]$last.time) -gt $runTime.AddMinutes(-$cooldownMin)) { $allow = $false; $why = "cooldown ($cooldownMin min) after full restart at $($last.time)" }
    elseif ($mine.Count -ge $cap) { $allow = $false; $why = "max $cap automatic '$plan' attempts in 24h reached - human needed" }
    foreach ($w in @($rem.maintenanceWindows)) {
        if (-not $w) { continue }
        $a = [datetime]::ParseExact($w.start, 'HH:mm', $null); $b = [datetime]::ParseExact($w.end, 'HH:mm', $null)
        $in = if ($a -le $b) { $runTime -ge $a -and $runTime -le $b } else { $runTime -ge $a -or $runTime -le $b }
        if ($in) { $allow = $false; $why = "maintenance window $($w.start)-$($w.end)" }
    }

    # 3. Notify user BEFORE acting
    $action = if ($plan -eq 'full') { 'stop all services, clear cache, restart (CPU is high)' } else { 'start the down service(s) automatically' }
    $pre = "<html><body style='font-family:Segoe UI,Arial;font-size:13px'><h2 style='background:#f8d7da;padding:8px'>$($cfg.environment) ALERT: $($srv.name) - service(s) DOWN</h2>" +
           "<p><b>Down:</b> $(Enc ($d.Down -join '; '))<br><b>CPU:</b> $($d.Cpu)%<br><b>Time:</b> $($runTime.ToString('yyyy-MM-dd HH:mm:ss'))<br>" +
           "<b>Agent will:</b> $(if ($allow) { if ($dry) {'(DRY RUN) '}; Enc $action } else { 'NOT act - ' + (Enc $why) })</p>" +
           "<pre>$(Enc ($d.Services -join "`n"))</pre></body></html>"
    Send-Notice "[$($cfg.environment)] ALERT $($srv.name): service(s) DOWN - $(if ($allow) {'auto-recovery starting'} else {'auto-recovery blocked'})" $pre

    if (-not $allow) {
        $tk = New-Incident "[AutoHeal][BLOCKED] $($srv.name) services down" "Down: $($d.Down -join '; ')`nBlocked: $why`nRun: $runId" 1
        $summary.Add([pscustomobject]@{ Server = $srv.name; Outcome = 'BLOCKED'; Reason = $why; Cpu = $d.Cpu; Services = $d.Services; Detail = ($d.Log -join "`n"); Ticket = $tk })
        continue
    }

    # 4. Act
    try { $r = Invoke-Agent $srv $isLocal $plan }
    catch {
        Write-Warning "[$($srv.name)] recovery failed: $($_.Exception.Message)"
        $tk = New-Incident "[AutoHeal][FAILED] $($srv.name) recovery error" "$($_.Exception.Message)`nRun: $runId" 1
        $summary.Add([pscustomobject]@{ Server = $srv.name; Outcome = 'FAILED'; Reason = $_.Exception.Message; Cpu = $d.Cpu; Services = $d.Services; Detail = ''; Ticket = $tk })
        continue
    }
    $r.Log | ForEach-Object { Write-Host "[$($srv.name)] $_" }

    # 5. Verify ports from the monitoring host
    $portNotes = @()
    if (-not $dry -and $r.Success) {
        foreach ($p in @($srv.ports)) {
            $up = $false
            for ($i = 0; $i -lt 6 -and -not $up; $i++) { $up = Test-Tcp $srv.name $p.port; if (-not $up) { Start-Sleep 10 } }
            $portNotes += "Port $($p.port) ($($p.name)): $(if ($up) {'UP'} else {'DOWN'})"
            if (-not $up) { $r.Success = $false; $r.Reason += " - but port $($p.port) not listening" }
        }
    }
    if (-not $dry) { $hist += [pscustomobject]@{ server = $srv.name; kind = $plan; time = $runTime.ToString('s'); success = [bool]$r.Success } }

    $outcome = if ($dry) { 'Campus Solution' } elseif ($r.Success) { if ($plan -eq 'full') { 'RECOVERED' } else { 'STARTED' } } else { 'FAILED' }
    $detail  = ($r.Log + $portNotes) -join "`n"
    $tk = ''
    if ($outcome -eq 'FAILED') { $tk = New-Incident "[AutoHeal][FAILED] $($srv.name) - could not recover services ($plan)" "$($r.Reason)`n`n$detail`nRun: $runId" 1 }
    elseif ($outcome -in 'STARTED','RECOVERED') { $tk = New-Incident "[AutoHeal][$outcome] $($srv.name) - services were down, recovered automatically" "$($r.Reason)`n`n$detail`nRun: $runId" 3 }
    $summary.Add([pscustomobject]@{ Server = $srv.name; Outcome = $outcome; Reason = $r.Reason; Cpu = $r.Cpu; Services = $r.Services; Detail = $detail; Ticket = $tk })
}

# ---------- Email on EVERY run ----------
$worst = if     ($summary | Where-Object { $_.Outcome -in 'FAILED','ERROR','BLOCKED' }) { 'FAILED' }
         elseif ($summary | Where-Object { $_.Outcome -in 'STARTED','RECOVERED' })      { 'RECOVERED' }
         elseif ($summary | Where-Object { $_.Outcome -eq 'DRY RUN' })                  { 'DRY RUN' }
         else { 'HEALTHY' }
$bg = @{ FAILED = '#f8d7da'; RECOVERED = '#fff3cd'; 'DRY RUN' = '#cce5ff'; HEALTHY = '#d4edda' }
$rows = ($summary | ForEach-Object {
    $svcHtml = (@($_.Services) | ForEach-Object { Enc $_ }) -join '<br>'
    "<tr><td>$(Enc $_.Server)</td><td><b>$($_.Outcome)</b></td><td>$($_.Cpu)%</td><td>$(Enc $_.Reason)</td><td>$svcHtml</td><td>$($_.Ticket)</td></tr><tr><td colspan='6'><pre style='margin:0;font-size:12px'>$(Enc $_.Detail)</pre></td></tr>"
}) -join "`n"
$html = "<html><body style='font-family:Segoe UI,Arial;font-size:13px'><h2 style='background:$($bg[$worst]);padding:8px'>$($cfg.environment) PeopleSoft AutoHeal - $worst$(if ($dry) {' (DRY RUN)'})</h2><p>Run: $($runTime.ToString('yyyy-MM-dd HH:mm:ss'))</p><table border='1' cellpadding='5' cellspacing='0' style='border-collapse:collapse'><tr style='background:#343a40;color:#fff'><th>Server</th><th>Outcome</th><th>CPU</th><th>Reason</th><th>Services</th><th>Ticket</th></tr>$rows</table></body></html>"
if ($summary.Count -gt 0) { Send-Notice "[$($cfg.environment)] PeopleSoft AutoHeal: $worst$(if ($dry -and $worst -ne 'DRY RUN') {' (dry run)'})" $html }

@{ attempts = @($hist) } | ConvertTo-Json -Depth 4 | Set-Content $stPath
Stop-Transcript | Out-Null

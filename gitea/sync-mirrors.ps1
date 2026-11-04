#requires -Version 5.1
<#
  Добавляет push-зеркало (sync on commit) на роутер ко всем репозиториям Gitea,
  у которых его ещё нет. Безопасно запускать повторно.
  Конфиг: config.json рядом со скриптом (см. config.example.json).
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $ConfigPath)) { throw "Нет файла $ConfigPath (скопируйте config.example.json)" }
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$api  = ($cfg.giteaUrl.TrimEnd('/')) + '/api/v1'
$base = $cfg.remoteBase.TrimEnd('/')
$hdr  = @{ Authorization = "token $($cfg.giteaToken)" }
$interval = if ($cfg.interval) { $cfg.interval } else { '8h0m0s' }

function Invoke-Api($method, $path, $body = $null) {
    $p = @{ Method = $method; Uri = "$api$path"; Headers = $hdr; ContentType = 'application/json' }
    if ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Compress) }
    Invoke-RestMethod @p
}

# Все доступные репозитории (с пагинацией)
$repos = @()
$page = 1
while ($true) {
    $chunk = Invoke-Api GET "/user/repos?limit=50&page=$page"
    if (-not $chunk -or $chunk.Count -eq 0) { break }
    $repos += $chunk
    if ($chunk.Count -lt 50) { break }
    $page++
}
Write-Host "Репозиториев: $($repos.Count)"

$added = 0; $skipped = 0; $failed = 0
foreach ($r in $repos) {
    $full   = $r.full_name                       # owner/repo
    $target = "$base/$full.git"
    try {
        $existing = @(Invoke-Api GET "/repos/$full/push_mirrors")
        if ($existing | Where-Object { $_.remote_address -like "$base/*" }) {
            $skipped++; continue
        }
        Invoke-Api POST "/repos/$full/push_mirrors" @{
            remote_address  = $target
            remote_username = $cfg.remoteUser
            remote_password = $cfg.remotePassword
            interval        = $interval
            sync_on_commit  = $true
            use_ssh         = $false
        } | Out-Null
        # Первичная выгрузка сразу, не дожидаясь интервала
        try { Invoke-Api POST "/repos/$full/push_mirrors-sync" | Out-Null } catch { }
        Write-Host "+ $full -> $target"
        $added++
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg += ' | ' + $_.ErrorDetails.Message }
        Write-Warning "$full : $msg"
        $failed++
    }
}
Write-Host "Добавлено: $added, уже было: $skipped, ошибок: $failed"

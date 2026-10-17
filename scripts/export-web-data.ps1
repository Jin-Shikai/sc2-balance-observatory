# Exports gold tables as JSON for the static balance dashboard (web/data/*.json).
# Requires: $env:DATABRICKS_HOST, $env:DATABRICKS_TOKEN, $env:DATABRICKS_WAREHOUSE_ID
param(
    [string]$WarehouseId = $env:DATABRICKS_WAREHOUSE_ID,
    [int]$WarehouseStartTimeoutSec = 600, # how long to wait for the warehouse to reach RUNNING
    [int]$MaxAttempts = 6                 # per statement, on transient warehouse errors
)

$ErrorActionPreference = 'Stop'
$dbxHost = $env:DATABRICKS_HOST.TrimEnd('/')
$headers = @{ Authorization = "Bearer $env:DATABRICKS_TOKEN" }
$outDir = Join-Path $PSScriptRoot '..\web\data'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Invoke-Dbx([string]$Method, [string]$Path, $Body = $null) {
    $params = @{ Method = $Method; Uri = "$dbxHost$Path"; Headers = $headers }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = $Body | ConvertTo-Json -Depth 5
    }
    Invoke-RestMethod @params
}

# Errors the warehouse returns while it is stopped, starting or overloaded.
# Free Edition auto-stops the starter warehouse, and a statement sent in that
# window can be rejected with BAD_REQUEST "could not be processed by the warehouse".
function Test-TransientError($err) {
    $status = 0
    try { $status = [int]$err.Exception.Response.StatusCode } catch {}
    if ($status -eq 429 -or $status -ge 500) { return $true }
    $msg = "$($err.ErrorDetails.Message) $($err.Exception.Message)"
    return $msg -match 'could not be processed by the warehouse|TEMPORARILY_UNAVAILABLE|RESOURCE_EXHAUSTED|is starting|STARTING'
}

# Make sure the warehouse is RUNNING before sending statements. Logs its state
# and health so a warehouse-side problem is visible in the job output.
function Wait-Warehouse {
    $deadline = (Get-Date).AddSeconds($WarehouseStartTimeoutSec)
    $nextStart = Get-Date
    while ($true) {
        $wh = Invoke-Dbx -Method Get -Path "/api/2.0/sql/warehouses/$WarehouseId"
        $state = "$($wh.state)"
        $health = ''
        if ($wh.health -and $wh.health.status -ne 'HEALTHY') {
            $health = " health=$($wh.health.status) $($wh.health.summary) $($wh.health.message)".TrimEnd()
        }
        Write-Host "warehouse '$($wh.name)' ($WarehouseId) state=$state$health"

        if ($state -eq 'RUNNING') { return }
        if ($state -in @('DELETED', 'DELETING')) {
            throw "warehouse $WarehouseId is $state; point DATABRICKS_WAREHOUSE_ID at an existing warehouse"
        }
        # (Re)issue the start request while STOPPED, at most once a minute.
        if ($state -eq 'STOPPED' -and (Get-Date) -ge $nextStart) {
            Write-Host 'starting warehouse...'
            try { Invoke-Dbx -Method Post -Path "/api/2.0/sql/warehouses/$WarehouseId/start" | Out-Null }
            catch {
                $msg = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
                # Free Edition: the workspace itself was flagged inactive and all compute is
                # denied. Waiting will not help; someone has to log in and reactivate it.
                if ($msg -match 'DENY_NEW_AND_EXISTING_RESOURCES|"denyReason":\s*"INACTIVE"') {
                    throw "Databricks refuses to start any compute in this workspace (workspace flagged INACTIVE). Log in to the workspace in a browser and start the warehouse once, then re-run. Response: $msg"
                }
                Write-Warning "start request failed: $msg"
            }
            $nextStart = (Get-Date).AddSeconds(60)
        }
        if ((Get-Date) -gt $deadline) {
            throw "warehouse $WarehouseId is not RUNNING after ${WarehouseStartTimeoutSec}s (state=$state$health)"
        }
        Start-Sleep -Seconds 10
    }
}

function Invoke-Sql([string]$Sql) {
    $body = @{
        statement    = $Sql
        warehouse_id = $WarehouseId
        wait_timeout = '30s'
        format       = 'JSON_ARRAY'
        disposition  = 'INLINE'
    }
    for ($attempt = 1; ; $attempt++) {
        try {
            $r = Invoke-Dbx -Method Post -Path '/api/2.0/sql/statements' -Body $body
            $pollDeadline = (Get-Date).AddMinutes(10)
            while ($r.status.state -in @('PENDING', 'RUNNING')) {
                if ((Get-Date) -gt $pollDeadline) { throw "statement $($r.statement_id) still $($r.status.state) after 10 minutes" }
                Start-Sleep -Seconds 2
                $r = Invoke-Dbx -Method Get -Path "/api/2.0/sql/statements/$($r.statement_id)"
            }
            if ($r.status.state -ne 'SUCCEEDED') { throw ($r.status | ConvertTo-Json -Depth 5) }
            break
        }
        catch {
            if ($attempt -ge $MaxAttempts -or -not (Test-TransientError $_)) { throw }
            $delay = 15 * $attempt
            Write-Warning "warehouse rejected the statement (attempt $attempt/$MaxAttempts), retrying in ${delay}s: $($_.ErrorDetails.Message) $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
            Wait-Warehouse
        }
    }

    $cols = @($r.manifest.schema.columns.name)
    $data = @($r.result.data_array)
    $next = $r.result.next_chunk_internal_link
    while ($next) {
        $chunk = Invoke-Dbx -Method Get -Path $next
        $data += @($chunk.data_array)
        $next = $chunk.next_chunk_internal_link
    }
    foreach ($row in $data) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

$queries = [ordered]@{
    'profile'      = @"
WITH base AS (
  SELECT season_bnet_id, region, league, matchup, wins, games
  FROM sc2.gold.balance_profile
  WHERE matchup IN ('PvT', 'TvZ', 'ZvP')
)
SELECT season_bnet_id, region, league, matchup,
       sum(wins) / sum(games) AS winrate, sum(games) AS games
FROM base GROUP BY ALL
UNION ALL
SELECT season_bnet_id, 'ALL', league, matchup,
       sum(wins) / sum(games), sum(games)
FROM base GROUP BY season_bnet_id, league, matchup
"@
    'game_length'  = @"
WITH bucketed AS (
  SELECT season_bnet_id, region, league, matchup,
         CASE WHEN league = 'GRANDMASTER' THEN floor(game_minute / 5) * 5
              ELSE game_minute END AS minute_bucket,
         wins, games
  FROM sc2.gold.balance_by_game_length
  WHERE matchup IN ('PvT', 'TvZ', 'ZvP') AND game_minute <= 40
)
SELECT season_bnet_id, region, league, matchup, minute_bucket,
       sum(wins) / sum(games) AS winrate, sum(games) AS games
FROM bucketed GROUP BY ALL HAVING sum(games) >= 100
UNION ALL
SELECT season_bnet_id, 'ALL', league, matchup, minute_bucket,
       sum(wins) / sum(games), sum(games)
FROM bucketed GROUP BY season_bnet_id, league, matchup, minute_bucket
HAVING sum(games) >= 100
"@
    'season_delta' = @"
SELECT season_bnet_id, region, league, matchup,
       round(100 * winrate_prev, 1) AS winrate_prev_pct,
       round(100 * winrate_cur, 1)  AS winrate_cur_pct,
       round(100 * winrate_delta, 1) AS delta_pct,
       delta_significant, patches_in_season, games_prev, games_cur
FROM sc2.gold.balance_season_delta
WHERE matchup IN ('PvT', 'TvZ', 'ZvP')
"@
    'patch_event'  = @"
SELECT version, release_ts, matchup,
       round(100 * winrate_delta, 1) AS delta_pct,
       delta_significant, games_pre, games_post
FROM sc2.gold.patch_event_study
WHERE matchup IN ('PvT', 'TvZ', 'ZvP')
  AND games_pre >= 100 AND games_post >= 100
ORDER BY release_ts
"@
}

Wait-Warehouse

# Run every query first, then write, so a failure half-way leaves web/data untouched.
$results = [ordered]@{}
foreach ($name in $queries.Keys) {
    Write-Host "exporting $name..."
    $rows = @(Invoke-Sql $queries[$name])
    if ($rows.Count -eq 0) { throw "$name returned 0 rows; refusing to overwrite web/data/$name.json" }
    Write-Host "  $($rows.Count) rows"
    $results[$name] = $rows
}

foreach ($name in $results.Keys) {
    $results[$name] | ConvertTo-Json -Depth 4 -AsArray | Set-Content (Join-Path $outDir "$name.json") -Encoding utf8
}
@{ generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
    ConvertTo-Json | Set-Content (Join-Path $outDir 'meta.json') -Encoding utf8
Write-Host 'done -> web/data/'

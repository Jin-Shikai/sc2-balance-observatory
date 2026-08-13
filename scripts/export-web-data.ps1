# Exports gold tables as JSON for the static balance dashboard (web/data/*.json).
# Requires: $env:DATABRICKS_HOST, $env:DATABRICKS_TOKEN, $env:DATABRICKS_WAREHOUSE_ID
param([string]$WarehouseId = $env:DATABRICKS_WAREHOUSE_ID)

$ErrorActionPreference = 'Stop'
$dbxHost = $env:DATABRICKS_HOST.TrimEnd('/')
$headers = @{ Authorization = "Bearer $env:DATABRICKS_TOKEN" }
$outDir = Join-Path $PSScriptRoot '..\web\data'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Invoke-Sql([string]$Sql) {
    $body = @{
        statement    = $Sql
        warehouse_id = $WarehouseId
        wait_timeout = '30s'
        format       = 'JSON_ARRAY'
        disposition  = 'INLINE'
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Method Post -Uri "$dbxHost/api/2.0/sql/statements" `
        -Headers $headers -ContentType 'application/json' -Body $body
    while ($r.status.state -in @('PENDING', 'RUNNING')) {
        Start-Sleep -Seconds 2
        $r = Invoke-RestMethod -Uri "$dbxHost/api/2.0/sql/statements/$($r.statement_id)" -Headers $headers
    }
    if ($r.status.state -ne 'SUCCEEDED') { throw ($r.status | ConvertTo-Json -Depth 5) }
    $cols = @($r.manifest.schema.columns.name)
    foreach ($row in $r.result.data_array) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

$queries = @{
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

foreach ($name in $queries.Keys) {
    Write-Host "exporting $name..."
    $rows = @(Invoke-Sql $queries[$name])
    $rows | ConvertTo-Json -Depth 4 -AsArray | Set-Content (Join-Path $outDir "$name.json") -Encoding utf8
    Write-Host "  $($rows.Count) rows"
}

@{ generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
    ConvertTo-Json | Set-Content (Join-Path $outDir 'meta.json') -Encoding utf8
Write-Host 'done -> web/data/'

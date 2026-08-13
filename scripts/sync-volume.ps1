# Incremental S3 -> Databricks volume sync.
# aws s3 sync is truly incremental; we upload only the files it just downloaded.
param(
    [string]$Bucket = 's3://sc2obs-raw-20260812145714297700000003/raw',
    [string]$Volume = 'dbfs:/Volumes/sc2/bronze/raw',
    [int]$Parallel = 8
)

$ErrorActionPreference = 'Stop'
$local = Join-Path $PSScriptRoot '..\raw'

Write-Host 'syncing S3 -> local...'
$lines = aws s3 sync $Bucket $local
$new = @($lines | Where-Object { $_ -match '^download: ' } |
    ForEach-Object { ($_ -split ' to ', 2)[1].Trim() })

if (-not $new.Count) { Write-Host 'nothing new'; exit 0 }
Write-Host "uploading $($new.Count) new files -> volume..."

$prefix = (Resolve-Path $local).Path
$new | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    $rel = ((Resolve-Path $_).Path.Substring($using:prefix.Length + 1)) -replace '\\', '/'
    databricks fs cp $_ "$using:Volume/$rel" --overwrite | Out-Null
    Write-Host "  $rel"
}
Write-Host 'done'

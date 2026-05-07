param(
    [ValidateSet('quick', 'medium', 'full')]
    [string]$Preset = 'quick',

    [string]$Url = 'http://localhost:8080',
    [string]$HmacSecret = 'dev-secret',
    [int]$Concurrency = $null,
    [string]$Duration = $null,
    [int]$BetsPerRound = $null
)

# Preset configurations
$presets = @{
    'quick' = @{
        concurrency = 10
        duration = '30s'
        betsPerRound = 5
        description = 'Smoke test: 10 players, 30 seconds'
    }
    'medium' = @{
        concurrency = 100
        duration = '5m'
        betsPerRound = 20
        description = 'CI-friendly: 100 players, 5 minutes'
    }
    'full' = @{
        concurrency = 1000
        duration = '30m'
        betsPerRound = 20
        description = 'Release gate: 1000 players, 30 minutes'
    }
}

$config = $presets[$Preset]

# Override with explicit parameters
if ($Concurrency) { $config.concurrency = $Concurrency }
if ($Duration) { $config.duration = $Duration }
if ($BetsPerRound) { $config.betsPerRound = $BetsPerRound }

Write-Host "Stress Test Runner"
Write-Host "==================" -ForegroundColor Cyan
Write-Host "Preset:      $Preset ($($config.description))"
Write-Host "URL:         $Url"
Write-Host "Concurrency: $($config.concurrency)"
Write-Host "Duration:    $($config.duration)"
Write-Host "Bets/round:  $($config.betsPerRound)"
Write-Host ""

# Check if Go is installed
$goPath = (Get-Command go -ErrorAction SilentlyContinue)
if (-not $goPath) {
    Write-Host "Error: Go is not installed or not in PATH" -ForegroundColor Red
    exit 1
}

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainGoPath = Join-Path $scriptDir "main.go"

if (-not (Test-Path $mainGoPath)) {
    Write-Host "Error: main.go not found at $mainGoPath" -ForegroundColor Red
    exit 1
}

# Build the stress test
Write-Host "Building stress test binary..." -ForegroundColor Yellow
$tempBuild = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.exe'
& go build -o $tempBuild $mainGoPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Build failed" -ForegroundColor Red
    exit 1
}

Write-Host "Starting test..." -ForegroundColor Yellow
Write-Host ""

# Run the stress test
& $tempBuild `
    -url=$Url `
    -hmac-secret=$HmacSecret `
    -concurrency=$($config.concurrency) `
    -duration=$($config.duration) `
    -bets-per-round=$($config.betsPerRound) `
    -think-time=1s

$exitCode = $LASTEXITCODE

# Cleanup
Remove-Item $tempBuild -Force -ErrorAction SilentlyContinue

exit $exitCode

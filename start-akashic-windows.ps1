Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$NapCatDir = "C:\Program Files\NapCat.Shell"
$NapCatLauncher = Join-Path $NapCatDir "launcher.bat"
$NapCatPort = 3001
$PythonExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$MainPy = Join-Path $RepoRoot "main.py"
$ConfigYaml = Join-Path $RepoRoot "config.yaml"

function Test-PortListening {
    param(
        [int]$Port
    )

    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$listeners
}

function Wait-PortListening {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortListening -Port $Port) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Wait-NapCatReady {
    param(
        [int]$Port
    )

    if (Wait-PortListening -Port $Port -TimeoutSeconds 180) {
        return $true
    }

    while (-not (Test-PortListening -Port $Port)) {
        Write-Host "[wait] NapCat is still not ready on port $Port." -ForegroundColor Yellow
        $answer = Read-Host "Finish login in NapCat, then press Enter to retry. Type q to quit"
        if ($answer -match '^(q|quit|exit)$') {
            return $false
        }
        if (Wait-PortListening -Port $Port -TimeoutSeconds 15) {
            return $true
        }
    }

    return $true
}

Write-Host "[start] Repo: $RepoRoot"

if (-not (Test-Path -LiteralPath $PythonExe)) {
    throw "Python virtualenv not found: $PythonExe"
}

if (-not (Test-Path -LiteralPath $MainPy)) {
    throw "main.py not found: $MainPy"
}

if (Test-Path -LiteralPath $ConfigYaml) {
    $configText = Get-Content -LiteralPath $ConfigYaml -Raw -ErrorAction SilentlyContinue
    if ($configText -match "ws_uri:\s*ws://(?!localhost:3001|127\.0\.0\.1:3001)([^\r\n]+)") {
        $currentWsUri = $Matches[1]
        Write-Host "[warn] config.yaml 当前 ws_uri = ws://$currentWsUri" -ForegroundColor Yellow
        Write-Host "[warn] config.yaml current ws_uri = ws://$currentWsUri" -ForegroundColor Yellow
        Write-Host "[warn] If you run Akashic on Windows, change it back to ws://localhost:3001" -ForegroundColor Yellow
    }
}

if (-not (Test-PortListening -Port $NapCatPort)) {
    if (-not (Test-Path -LiteralPath $NapCatLauncher)) {
        throw "NapCat launcher not found: $NapCatLauncher"
    }
    Write-Host "[start] NapCat is not listening on $NapCatPort, starting it now..."
    Start-Process -FilePath $NapCatLauncher -WorkingDirectory $NapCatDir
    if (-not (Wait-NapCatReady -Port $NapCatPort)) {
        throw "NapCat was not ready. Start was cancelled by user."
    }
    Write-Host "[start] NapCat is now listening on $NapCatPort"
} else {
    Write-Host "[start] NapCat is already listening on port $NapCatPort"
}

Write-Host "[start] Starting Akashic..."
Set-Location -LiteralPath $RepoRoot
& $PythonExe $MainPy

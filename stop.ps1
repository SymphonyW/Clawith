[CmdletBinding()]
param(
    [switch]$Containers,
    [switch]$Wsl
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root ".data"
$PidDir = Join-Path $DataDir "pid"

$BackendPid = Join-Path $PidDir "backend.pid"
$FrontendPid = Join-Path $PidDir "frontend.pid"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  WARN  $Message" -ForegroundColor Yellow
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ChildProcessIds {
    param([int]$ProcessId)

    try {
        Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" |
            Select-Object -ExpandProperty ProcessId
    }
    catch {
        @()
    }
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    foreach ($childId in Get-ChildProcessIds $ProcessId) {
        Stop-ProcessTree ([int]$childId)
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-ManagedProcess {
    param(
        [string]$Name,
        [string]$PidFile
    )

    if (-not (Test-Path $PidFile)) {
        Write-Warn "$Name pid file not found; it may already be stopped"
        return
    }

    $rawPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue

    if (-not $rawPid) {
        Write-Warn "$Name pid file was empty"
        return
    }

    $processId = [int]$rawPid
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) {
        Write-Warn "$Name process $processId was not running"
        return
    }

    Stop-ProcessTree $processId
    Write-Ok "Stopped $Name (PID $processId)"
}

function Stop-DockerContainerIfRunning {
    param([string]$Name)

    if (-not (Test-CommandExists "docker")) {
        Write-Warn "Docker was not found; skipping $Name"
        return
    }

    $running = & docker inspect -f "{{.State.Running}}" $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Container $Name not found"
        return
    }

    if ($running -eq "true") {
        & docker stop $Name > $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Stopped container $Name"
        }
        else {
            Write-Warn "Failed to stop container $Name"
        }
    }
    else {
        Write-Warn "Container $Name is already stopped"
    }
}

function Stop-WslDistroIfRunning {
    param([string]$Name)

    if (-not (Test-CommandExists "wsl.exe")) {
        Write-Warn "wsl.exe was not found; skipping $Name"
        return
    }

    $list = & wsl.exe -l -v 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $list) {
        Write-Warn "Could not inspect WSL distros"
        return
    }

    $isRunning = $false
    foreach ($line in $list) {
        $plain = ($line -replace "`0", "").Trim()
        if ($plain -match [regex]::Escape($Name) -and $plain -match "Running") {
            $isRunning = $true
            break
        }
    }

    if (-not $isRunning) {
        Write-Warn "WSL distro $Name is not running"
        return
    }

    & wsl.exe -t $Name
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Stopped WSL distro $Name"
    }
    else {
        Write-Warn "Failed to stop WSL distro $Name"
    }
}

function Show-PortOwners {
    $ports = @(3008, 3009, 8008, 8009)
    $listeners = Get-NetTCPConnection -LocalPort $ports -State Listen -ErrorAction SilentlyContinue
    if (-not $listeners) {
        return
    }

    Write-Host ""
    Write-Warn "Some common Clawith ports are still in use:"
    foreach ($listener in ($listeners | Sort-Object LocalPort)) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        $name = if ($process) { $process.ProcessName } else { "unknown" }
        Write-Warn "Port $($listener.LocalPort) is owned by PID $($listener.OwningProcess) ($name)"
    }
    Write-Host "If these are old WSL services, run: .\stop.ps1 -Wsl" -ForegroundColor Yellow
}

Write-Host "Clawith Windows stop (PowerShell, no WSL)" -ForegroundColor Cyan

Write-Step "Stopping app services"
Stop-ManagedProcess "backend" $BackendPid
Stop-ManagedProcess "frontend" $FrontendPid

if ($Containers) {
    Write-Step "Stopping database containers"
    Stop-DockerContainerIfRunning "clawith-postgres"
    Stop-DockerContainerIfRunning "clawith-redis"
}
else {
    Write-Host ""
    Write-Host "PostgreSQL and Redis containers were left running." -ForegroundColor Yellow
    Write-Host "To stop them too, run: .\stop.ps1 -Containers"
}

if ($Wsl) {
    Write-Step "Stopping old WSL user distro"
    Stop-WslDistroIfRunning "Ubuntu-22.04"
}

Show-PortOwners

Write-Host ""
Write-Host "Stop complete." -ForegroundColor Green

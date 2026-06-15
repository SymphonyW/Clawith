[CmdletBinding()]
param(
    [int]$BackendPort = 8008,
    [int]$FrontendPort = 3008
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDir = Join-Path $Root "backend"
$FrontendDir = Join-Path $Root "frontend"
$DataDir = Join-Path $Root ".data"
$PidDir = Join-Path $DataDir "pid"
$LogDir = Join-Path $DataDir "log"
$EnvFile = Join-Path $Root ".env"

$BackendPid = Join-Path $PidDir "backend.pid"
$FrontendPid = Join-Path $PidDir "frontend.pid"
$BackendLog = Join-Path $LogDir "backend.log"
$BackendErrLog = Join-Path $LogDir "backend.err.log"
$FrontendLog = Join-Path $LogDir "frontend.log"
$FrontendErrLog = Join-Path $LogDir "frontend.err.log"

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

function Get-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }
    if ($command.Source) {
        return $command.Source
    }
    return $command.Path
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $Root
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath exited with code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

function Set-LocalhostUrlPort {
    param(
        [string]$Url,
        [int]$Port,
        [string]$DefaultUrl
    )

    if ($Url -match 'localhost:\d+') {
        return ($Url -replace 'localhost:\d+', "localhost:$Port")
    }
    return $DefaultUrl
}

function Ensure-Docker {
    if (-not (Test-CommandExists "docker")) {
        throw "Docker was not found. Install Docker Desktop and start it before running restart.ps1."
    }

    $stdout = New-TemporaryFile
    $stderr = New-TemporaryFile
    try {
        $process = Start-Process `
            -FilePath "docker" `
            -ArgumentList @("info") `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdout.FullName `
            -RedirectStandardError $stderr.FullName `
            -PassThru

        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Write-Host @"
Docker Desktop did not respond to 'docker info' within 15 seconds.

Fix:
  1. Open Docker Desktop.
  2. Use Troubleshoot -> Restart Docker Desktop.
  3. Wait until Docker Desktop says it is running.
  4. Re-run: .\restart.ps1
"@ -ForegroundColor Red
            exit 1
        }

        $stdoutText = Get-Content -Raw $stdout.FullName -ErrorAction SilentlyContinue
        $stderrText = Get-Content -Raw $stderr.FullName -ErrorAction SilentlyContinue
        if ($stdoutText -match "Server Version:") {
            return
        }

        if ($process.ExitCode -ne 0 -or $stderrText) {
            $message = (($stderrText, $stdoutText) -join "`n").Trim()
            if (-not $message) {
                $message = "docker info exited with code $($process.ExitCode)."
            }
            Write-Host @"
Docker Desktop is installed, but its daemon is not healthy.

Docker said:
$message

Fix:
  1. Open Docker Desktop.
  2. Use Troubleshoot -> Restart Docker Desktop.
  3. If the message mentions an unsupported API version, update Docker Desktop.
  4. Re-run: .\restart.ps1
"@ -ForegroundColor Red
            exit 1
        }
    }
    finally {
        Remove-Item -LiteralPath $stdout.FullName, $stderr.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-DockerContainer {
    param(
        [string]$Name,
        [string]$Image,
        [string[]]$RunArgs
    )

    $existing = & docker ps -a --filter "name=^/$Name$" --format "{{.Names}}"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect Docker containers."
    }

    if (@($existing) -contains $Name) {
        $running = (& docker inspect -f "{{.State.Running}}" $Name).Trim()
        if ($running -ne "true") {
            Invoke-External "docker" @("start", $Name)
            Write-Ok "Started existing container $Name"
        }
        else {
            Write-Ok "Container $Name already running"
        }
        return
    }

    Invoke-External "docker" (@("run", "-d", "--name", $Name) + $RunArgs + @($Image))
    Write-Ok "Created container $Name"
}

function Get-ContainerHostPort {
    param(
        [string]$Name,
        [int]$ContainerPort
    )

    try {
        $json = & docker inspect $Name --format "{{json .NetworkSettings.Ports}}" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) {
            return $null
        }
        $ports = $json | ConvertFrom-Json
        $key = "$ContainerPort/tcp"
        $mapping = $ports.PSObject.Properties[$key].Value | Select-Object -First 1
        if (-not $mapping -or -not $mapping.HostPort) {
            return $null
        }
        return [int]$mapping.HostPort
    }
    catch {
        return $null
    }
}

function Wait-ForPostgres {
    for ($i = 1; $i -le 30; $i++) {
        & docker exec clawith-postgres pg_isready -U clawith -d clawith > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "PostgreSQL ready"
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "PostgreSQL did not become ready in time."
}

function Wait-ForRedis {
    for ($i = 1; $i -le 20; $i++) {
        $pong = & docker exec clawith-redis redis-cli ping 2>$null
        if ($LASTEXITCODE -eq 0 -and $pong -match "PONG") {
            Write-Ok "Redis ready"
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "Redis did not become ready in time."
}

function Stop-ManagedProcess {
    param(
        [string]$Name,
        [string]$PidFile
    )

    if (-not (Test-Path $PidFile)) {
        return
    }

    $rawPid = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if (-not $rawPid) {
        return
    }

    $process = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $process.Id -Force
        Write-Ok "Stopped $Name (PID $rawPid)"
    }
}

function Test-PortInUse {
    param([int]$Port)
    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        return [bool]$connection
    }
    catch {
        return $false
    }
}

function Find-FreePort {
    param([int]$StartPort)
    $port = $StartPort
    while (Test-PortInUse $port) {
        Write-Warn "Port $port is in use, trying $($port + 1)"
        $port += 1
    }
    return $port
}

function Wait-ForHttp {
    param(
        [string]$Name,
        [string]$Url,
        [int]$TimeoutSeconds = 20
    )

    for ($i = 1; $i -le $TimeoutSeconds; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2 > $null
            Write-Ok "$Name ready"
            return $true
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }

    Write-Warn "$Name did not answer at $Url within ${TimeoutSeconds}s"
    return $false
}

function Start-ManagedProcess {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$StdoutLog,
        [string]$StderrLog,
        [string]$PidFile
    )

    Remove-Item -LiteralPath $StdoutLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StderrLog -Force -ErrorAction SilentlyContinue

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -PassThru

    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII
    Write-Ok "Started $Name (PID $($process.Id))"
}

Write-Host "Clawith Windows restart (PowerShell, no WSL)" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $PidDir, $LogDir > $null
Import-DotEnv $EnvFile

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$env:DATABASE_URL = if ($env:DATABASE_URL) { $env:DATABASE_URL } else { "postgresql+asyncpg://clawith:clawith@localhost:5432/clawith?ssl=disable" }
$env:REDIS_URL = if ($env:REDIS_URL) { $env:REDIS_URL } else { "redis://localhost:6379/0" }
$env:PROCESS_ROLE = if ($env:PROCESS_ROLE) { $env:PROCESS_ROLE } else { "all" }

Write-Step "Stopping existing PowerShell-managed services"
Stop-ManagedProcess "backend" $BackendPid
Stop-ManagedProcess "frontend" $FrontendPid
Start-Sleep -Milliseconds 500

$BackendPort = Find-FreePort $BackendPort
$FrontendPort = Find-FreePort $FrontendPort

Write-Step "Starting PostgreSQL and Redis containers"
Ensure-Docker

$desiredPostgresPort = 5432
if ($env:DATABASE_URL -match 'localhost:(\d+)/') {
    $desiredPostgresPort = [int]$Matches[1]
}
$desiredRedisPort = 6379
if ($env:REDIS_URL -match 'localhost:(\d+)/') {
    $desiredRedisPort = [int]$Matches[1]
}

$postgresExistingPort = Get-ContainerHostPort "clawith-postgres" 5432
$redisExistingPort = Get-ContainerHostPort "clawith-redis" 6379
$PostgresContainerPort = if ($postgresExistingPort) { $postgresExistingPort } elseif (Test-PortInUse $desiredPostgresPort) { Find-FreePort ($desiredPostgresPort + 1) } else { $desiredPostgresPort }
$RedisContainerPort = if ($redisExistingPort) { $redisExistingPort } elseif (Test-PortInUse $desiredRedisPort) { Find-FreePort ($desiredRedisPort + 1) } else { $desiredRedisPort }

$env:DATABASE_URL = Set-LocalhostUrlPort $env:DATABASE_URL $PostgresContainerPort "postgresql+asyncpg://clawith:clawith@localhost:$PostgresContainerPort/clawith?ssl=disable"
$env:REDIS_URL = Set-LocalhostUrlPort $env:REDIS_URL $RedisContainerPort "redis://localhost:$RedisContainerPort/0"
Write-Ok "Using PostgreSQL on localhost:$PostgresContainerPort"
Write-Ok "Using Redis on localhost:$RedisContainerPort"

Ensure-DockerContainer "clawith-postgres" "postgres:15" @(
    "-p", "${PostgresContainerPort}:5432",
    "-e", "POSTGRES_USER=clawith",
    "-e", "POSTGRES_PASSWORD=clawith",
    "-e", "POSTGRES_DB=clawith"
)
Ensure-DockerContainer "clawith-redis" "redis:7" @(
    "-p", "${RedisContainerPort}:6379"
)
Wait-ForPostgres
Wait-ForRedis

$venvPython = Join-Path $BackendDir ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    $linuxVenvPython = Join-Path $BackendDir ".venv\bin\python"
    if (Test-Path $linuxVenvPython) {
        throw "backend\.venv is a Linux/WSL virtual environment. Install Windows Python 3.11+ and run .\setup.ps1 -Dev to recreate it for PowerShell."
    }
    throw "Backend virtual environment was not found. Install Windows Python 3.11+ and run .\setup.ps1 -Dev first."
}

$npm = Get-CommandPath "npm.cmd"
if (-not $npm) {
    $npm = Get-CommandPath "npm"
}
if (-not $npm) {
    throw "npm was not found. Install Node.js 18+ and run .\setup.ps1 -Dev first."
}
if (-not (Test-Path (Join-Path $FrontendDir "node_modules"))) {
    throw "frontend\node_modules was not found. Run .\setup.ps1 -Dev first."
}
$viteCmd = Join-Path $FrontendDir "node_modules\.bin\vite.cmd"
if (-not (Test-Path $viteCmd)) {
    throw "frontend\node_modules is missing Windows command shims such as vite.cmd. Run .\setup.ps1 -Dev to recreate frontend dependencies for PowerShell."
}

Write-Step "Running database maintenance"
Invoke-External $venvPython @("-m", "alembic", "upgrade", "head") $BackendDir
Invoke-External $venvPython @("-m", "app.scripts.migrate_schedules_to_triggers") $BackendDir

Write-Step "Starting backend"
Start-ManagedProcess `
    -Name "backend" `
    -FilePath $venvPython `
    -Arguments @("-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "$BackendPort") `
    -WorkingDirectory $BackendDir `
    -StdoutLog $BackendLog `
    -StderrLog $BackendErrLog `
    -PidFile $BackendPid

Wait-ForHttp "Backend" "http://localhost:$BackendPort/api/health" 20 | Out-Null

Write-Step "Starting frontend"
$env:CI = "true"
$env:BACKEND_PORT = "$BackendPort"
Start-ManagedProcess `
    -Name "frontend" `
    -FilePath $npm `
    -Arguments @("run", "dev", "--", "--host", "0.0.0.0", "--port", "$FrontendPort", "--strictPort") `
    -WorkingDirectory $FrontendDir `
    -StdoutLog $FrontendLog `
    -StderrLog $FrontendErrLog `
    -PidFile $FrontendPid

Wait-ForHttp "Frontend" "http://localhost:$FrontendPort" 20 | Out-Null

Write-Step "Verifying API proxy"
try {
    Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$FrontendPort/api/health" -TimeoutSec 3 > $null
    Write-Ok "Proxy working"
}
catch {
    Write-Warn "Proxy may need a moment. Backend direct URL: http://localhost:$BackendPort/api/health"
}

Write-Host ""
Write-Host "Clawith running." -ForegroundColor Green
Write-Host "  Frontend: http://localhost:$FrontendPort"
Write-Host "  Backend:  http://localhost:$BackendPort"
Write-Host "  Logs:     $LogDir"

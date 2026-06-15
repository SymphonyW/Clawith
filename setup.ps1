[CmdletBinding()]
param(
    [switch]$Dev
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDir = Join-Path $Root "backend"
$FrontendDir = Join-Path $Root "frontend"
$EnvFile = Join-Path $Root ".env"
$EnvExample = Join-Path $Root ".env.example"

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

function Resolve-Python {
    $candidates = @()

    if ($env:PYTHON_BIN) {
        $candidates += [pscustomobject]@{ File = $env:PYTHON_BIN; Args = @() }
    }
    if (Test-CommandExists "py") {
        $candidates += [pscustomobject]@{ File = "py"; Args = @("-3.12") }
        $candidates += [pscustomobject]@{ File = "py"; Args = @("-3.11") }
    }
    if (Test-CommandExists "python") {
        $candidates += [pscustomobject]@{ File = "python"; Args = @() }
    }
    if (Test-CommandExists "python3") {
        $candidates += [pscustomobject]@{ File = "python3"; Args = @() }
    }

    foreach ($candidate in $candidates) {
        $file = $candidate.File
        $args = @($candidate.Args)
        & $file @args -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $version = & $file @args -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
            return [pscustomobject]@{ File = $file; Args = $args; Version = $version }
        }
    }

    Write-Host @"
Python 3.11+ was not found on Windows.

Install one of:
  winget install --id Python.Python.3.12 -e
  or download Python from https://www.python.org/downloads/ and enable Add to PATH.

Then close and reopen the VSCode terminal and re-run:
  .\setup.ps1 -Dev
"@ -ForegroundColor Red
    exit 1
}

function Set-DotEnvValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    $line = "$Key=$Value"
    $pattern = "^\s*#?\s*$([regex]::Escape($Key))="

    if (Test-Path $Path) {
        $lines = @(Get-Content -LiteralPath $Path)
    }
    else {
        $lines = @()
    }

    $found = $false
    $updated = foreach ($existing in $lines) {
        if (-not $found -and $existing -match $pattern) {
            $found = $true
            $line
        }
        else {
            $existing
        }
    }

    if (-not $found) {
        $updated += $line
    }

    Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8
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

function Ensure-Docker {
    if (-not (Test-CommandExists "docker")) {
        throw "Docker was not found. Install Docker Desktop and start it before running setup.ps1."
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
  4. Re-run: .\setup.ps1 -Dev
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
  4. Re-run: .\setup.ps1 -Dev
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

Write-Host "Clawith Windows setup (PowerShell, no WSL)" -ForegroundColor Cyan

Write-Step "[1/6] Checking .env"
if (-not (Test-Path $EnvFile)) {
    if (-not (Test-Path $EnvExample)) {
        throw ".env.example was not found."
    }
    Copy-Item -LiteralPath $EnvExample -Destination $EnvFile
    Write-Ok "Created .env from .env.example"
}
else {
    Write-Ok ".env already exists"
}

Write-Step "[2/6] Starting PostgreSQL and Redis with Docker Desktop"
Ensure-Docker

$postgresExistingPort = Get-ContainerHostPort "clawith-postgres" 5432
$redisExistingPort = Get-ContainerHostPort "clawith-redis" 6379
$PostgresPort = if ($postgresExistingPort) { $postgresExistingPort } else { Find-FreePort 5432 }
$RedisPort = if ($redisExistingPort) { $redisExistingPort } else { Find-FreePort 6379 }

Set-DotEnvValue $EnvFile "DATABASE_URL" "postgresql+asyncpg://clawith:clawith@localhost:$PostgresPort/clawith?ssl=disable"
Set-DotEnvValue $EnvFile "REDIS_URL" "redis://localhost:$RedisPort/0"
Write-Ok "DATABASE_URL set to localhost:$PostgresPort"
Write-Ok "REDIS_URL set to localhost:$RedisPort"

Ensure-DockerContainer "clawith-postgres" "postgres:15" @(
    "-p", "${PostgresPort}:5432",
    "-e", "POSTGRES_USER=clawith",
    "-e", "POSTGRES_PASSWORD=clawith",
    "-e", "POSTGRES_DB=clawith"
)
Ensure-DockerContainer "clawith-redis" "redis:7" @(
    "-p", "${RedisPort}:6379"
)
Wait-ForPostgres
Wait-ForRedis

Write-Step "[3/6] Setting up backend"
$venvDir = Join-Path $BackendDir ".venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"

if (Test-Path $venvPython) {
    $venvVersion = & $venvPython -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
    Write-Ok "Using existing Windows virtual environment (Python $venvVersion)"
}
else {
    $linuxVenvPython = Join-Path $venvDir "bin\python"
    if (Test-Path $linuxVenvPython) {
        Write-Warn "Existing backend\.venv looks like a Linux/WSL virtual environment and cannot be used from Windows PowerShell."
    }

    $python = Resolve-Python
    Write-Ok "Using Python $($python.Version)"

    if (Test-Path $venvDir) {
        Write-Warn "Removing non-Windows backend\.venv so it can be recreated for PowerShell."
        Remove-Item -LiteralPath $venvDir -Recurse -Force
    }

    Invoke-External $python.File (@($python.Args) + @("-m", "venv", $venvDir))
    Write-Ok "Created backend virtual environment"
}

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

Invoke-External $venvPython @("-m", "pip", "install", "--upgrade", "pip") $BackendDir

$pipTarget = "."
if ($Dev) {
    $pipTarget = ".[dev]"
}

$pipArgs = @("-m", "pip", "install", "-e", $pipTarget)
if ($env:CLAWITH_PIP_INDEX_URL) {
    $pipArgs += @("--index-url", $env:CLAWITH_PIP_INDEX_URL)
}
if ($env:CLAWITH_PIP_TRUSTED_HOST) {
    $pipArgs += @("--trusted-host", $env:CLAWITH_PIP_TRUSTED_HOST)
}

Invoke-External $venvPython $pipArgs $BackendDir
Write-Ok "Backend dependencies installed"

Write-Step "[4/6] Setting up frontend"
$npm = Get-CommandPath "npm.cmd"
if (-not $npm) {
    $npm = Get-CommandPath "npm"
}
if (-not $npm) {
    Write-Warn "npm was not found. Install Node.js 18+ to run the frontend dev server."
}
else {
    $nodeModules = Join-Path $FrontendDir "node_modules"
    $viteCmd = Join-Path $nodeModules ".bin\vite.cmd"
    $viteUnix = Join-Path $nodeModules ".bin\vite"
    if ((Test-Path $nodeModules) -and (Test-Path $viteUnix) -and -not (Test-Path $viteCmd)) {
        Write-Warn "Existing frontend\node_modules looks like a Linux/WSL install and cannot run Vite from Windows."
        Write-Warn "Removing frontend\node_modules so npm can recreate Windows command shims."
        Remove-Item -LiteralPath $nodeModules -Recurse -Force
    }
}

if ($npm -and -not (Test-Path (Join-Path $FrontendDir "node_modules"))) {
    Invoke-External $npm @("install") $FrontendDir
    Write-Ok "Frontend dependencies installed"
}
elseif ($npm) {
    Write-Ok "Frontend dependencies already installed"
}

Write-Step "[5/6] Migrating database"
Import-DotEnv $EnvFile
Invoke-External $venvPython @("-m", "alembic", "upgrade", "head") $BackendDir
Write-Ok "Database migrations complete"

Write-Step "[6/6] Seeding database"
Invoke-External $venvPython @("seed.py") $BackendDir
Write-Ok "Seed complete"

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "Start Clawith without WSL:"
Write-Host "  .\restart.ps1"
Write-Host ""
Write-Host "Frontend: http://localhost:3008"
Write-Host "Backend:  http://localhost:8008"

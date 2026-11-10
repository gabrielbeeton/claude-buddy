# Builds Buddy.exe, Buddy's desktop pet for Windows, into .\build.
# Pass -Install to copy it to %LOCALAPPDATA%\Buddy and start it.
#
# It uses the C# compiler that is part of Windows itself (.NET Framework 4), so there is
# nothing to download or install first.
param([switch]$Install)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $here 'build'
$exe = Join-Path $build 'Buddy.exe'
$product = 'Buddy desktop pet'

$csc = $null
foreach ($framework in 'Framework64', 'FrameworkArm64', 'Framework') {
    $candidate = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
    if (Test-Path $candidate) { $csc = $candidate; break }
}
if (-not $csc) {
    Write-Host 'Could not find the C# compiler that comes with Windows (.NET Framework 4).'
    Write-Host 'Turn on ".NET Framework 4.8" in "Turn Windows features on or off", then try again.'
    exit 1
}

function Compile([string]$output, [string]$icon) {
    $options = @(
        '/nologo', '/target:winexe', '/optimize+', '/codepage:65001', '/warn:1',
        '/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll',
        '/r:System.Windows.Forms.dll', '/r:System.Web.Extensions.dll',
        "/out:$output"
    )
    if ($icon) { $options += "/win32icon:$icon" }
    $sources = Get-ChildItem -Path $here -Filter '*.cs' | ForEach-Object { $_.FullName }
    & $csc @options @sources | Out-Host
    return ($LASTEXITCODE -eq 0)
}

if (Test-Path $build) { Remove-Item -Recurse -Force $build }
New-Item -ItemType Directory -Force -Path $build | Out-Null

if (-not (Compile $exe '')) {
    Write-Host 'Buddy did not build.'
    exit 1
}

# App icon, drawn by Buddy itself. Buddy still works without it.
$icon = Join-Path $build 'Buddy.ico'
$withIcon = Join-Path $build 'Buddy-icon.exe'
try {
    $draw = Start-Process -FilePath $exe -ArgumentList '--render-icon', "`"$icon`"" -Wait -PassThru
    if ($draw.ExitCode -eq 0 -and (Test-Path $icon) -and (Compile $withIcon $icon)) {
        Remove-Item -Force $exe
        Rename-Item -Path $withIcon -NewName 'Buddy.exe'
    } else {
        Write-Host 'Built without an icon.'
    }
} catch {
    Write-Host "Built without an icon: $_"
}
if (Test-Path $withIcon) { Remove-Item -Force $withIcon }
Write-Host "Built $exe"

if ($Install) {
    $folder = Join-Path $env:LOCALAPPDATA 'Buddy'
    $target = Join-Path $folder 'Buddy.exe'
    if (Test-Path $target) {
        if ((Get-Item $target).VersionInfo.ProductName -ne $product) {
            Write-Host "Refusing to replace ${target}: it is not Buddy."
            exit 1
        }
        # Ask a running Buddy to quit, and stop it if it does not.
        $running = @(Get-Process -Name 'Buddy' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $target })
        if ($running.Count -gt 0) {
            $root = Join-Path $env:USERPROFILE '.claude\buddy'
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            Set-Content -Path (Join-Path $root 'quit') -Value 'bye' -Encoding ASCII
            foreach ($process in $running) {
                if (-not $process.WaitForExit(4000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            }
            Start-Sleep -Milliseconds 300
            Remove-Item -Force (Join-Path $root 'quit') -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    Copy-Item -Force -Path $exe -Destination $target
    Start-Process -FilePath $target
    Write-Host "Installed and started $target"
}

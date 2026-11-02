# BD-only reproduction. No IP output generation, synthesis, or hardware access.
param(
    [Parameter(Mandatory)][string]$VivadoHome,
    [Parameter(Mandatory)][string]$AdiRoot,
    [Parameter(Mandatory)][string]$Staged,
    [Parameter(Mandatory)][string]$Work,
    [string]$AdiLibrary,
    [switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
function FileDigest([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Work = [IO.Path]::GetFullPath($Work)
$Staged = [IO.Path]::GetFullPath($Staged)
$AdiRoot = [IO.Path]::GetFullPath($AdiRoot)
$VivadoHome = [IO.Path]::GetFullPath($VivadoHome)
if (Test-Path -LiteralPath $Work) { throw 'Use a fresh Work directory' }
$tool = Join-Path $VivadoHome 'bin/vivado.bat'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'Missing explicit Vivado tool' }
$revision = & git -C $AdiRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision.Trim() -cne '2156ac7e874a1dc321d9f64a325009fafe563419') { throw 'ADI commit differs' }
$dirty = & git -C $AdiRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'ADI tracked source differs' }
if (-not $AdiLibrary) { $AdiLibrary = Join-Path $AdiRoot 'library' }
$AdiLibrary = [IO.Path]::GetFullPath($AdiLibrary)
if (-not (Test-Path -LiteralPath $AdiLibrary -PathType Container)) { throw 'Selected ADI library missing' }
$prep = Get-Content -LiteralPath "$Staged/preparation.json" -Raw | ConvertFrom-Json
foreach ($row in $prep.copied_files) {
    $path = Join-Path $Staged $row.staged_path
    if ((FileDigest $path) -ine $row.sha256) { throw "Staged input differs: $path" }
    if ((FileDigest (Join-Path $root "src/$($row.package_path)")) -ine $row.sha256) { throw "Package input differs: $($row.package_path)" }
}
if ((FileDigest "$Staged/inputs/system.bd") -ine $prep.staged_bd_sha256) { throw 'Staged BD differs' }
$pattern = '(?ms)\bmodule\s+ofdm_development_core\s*\(.*?^\);'
$headers = @("$root/src/platform/seed/legacy_core_stub.v", "$root/src/rtl/ofdm/lean/ofdm_development_core.v") | ForEach-Object {
    $matches = [regex]::Matches((Get-Content -LiteralPath $_ -Raw), $pattern)
    if ($matches.Count -ne 1) { throw 'Expected exactly one core header' }
    ($matches[0].Value -replace '\breg\b','wire') -replace '\s+',''
}
if ($headers[0] -cne $headers[1]) { throw 'Current core interface differs from shell stub' }
if ($PreflightOnly) {
    [pscustomobject]@{status='BD_PREFLIGHT_PASS';eda_executed=$false;interface_equal=$true;adi_commit=$revision.Trim();adi_library=$AdiLibrary} | ConvertTo-Json
    exit 0
}
$free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
if ($free -lt 2.5) { throw "BD-only launch needs 2.5 GiB free; available $([math]::Round($free,2)) GiB" }
if (Get-Process vivado,xelab,xsim -ErrorAction SilentlyContinue) { throw 'Another EDA process is running' }
New-Item -ItemType Directory -Path $Work | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot/validate_platform_bd.tcl" -Destination "$Work/validate_platform_bd.tcl"
$timer = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
$nativeExit = $null
Push-Location $Work
try {
    & $tool -mode batch -notrace -source "$Work/validate_platform_bd.tcl" -log "$Work/vivado.log" -journal "$Work/vivado.jou" -tclargs "$Staged/inputs" $AdiLibrary "$Work/project" 2>&1 | Tee-Object -FilePath "$Work/console.log"
    $nativeExit = $LASTEXITCODE
    if ($nativeExit -ne 0) { throw "BD validation native exit $nativeExit" }
    $result = Get-Content -LiteralPath "$Work/project/bd_result.json" -Raw | ConvertFrom-Json
    if ($result.status -cne 'BD_CONTRACT_VALIDATE_REOPEN_PASS_WITH_NOTES') { throw 'Missing successful native result' }
    $exitCode = 0
} catch {
    $_ | Out-String | Add-Content -LiteralPath "$Work/error.txt"
    Write-Output $_
} finally {
    Pop-Location
    [pscustomobject]@{exit_code=$exitCode;native_exit=$nativeExit;elapsed_seconds=$timer.Elapsed.TotalSeconds;free_gib_at_start=$free;staged=$Staged;adi_root=$AdiRoot;adi_library=$AdiLibrary;vivado_home=$VivadoHome} | ConvertTo-Json | Set-Content -LiteralPath "$Work/exit.json" -Encoding UTF8
}
exit $exitCode

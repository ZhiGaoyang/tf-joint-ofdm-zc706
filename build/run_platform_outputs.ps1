# Full BD output generation from an accepted BD project (made by run_platform_bd.ps1).
# Copies only the XPR and *.srcs into a fresh Work, generates products/wrapper,
# then gates on persisted BD/XCI state. No synthesis, implementation or hardware access.
param(
    [Parameter(Mandatory)][string]$VivadoHome,
    [Parameter(Mandatory)][string]$BdProject,
    [Parameter(Mandatory)][string]$AdiLibrary,
    [Parameter(Mandatory)][string]$Work,
    [double]$MinFreeGiB = 3.5,
    [switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
$Work = [IO.Path]::GetFullPath($Work)
$BdProject = [IO.Path]::GetFullPath($BdProject)
$AdiLibrary = [IO.Path]::GetFullPath($AdiLibrary)
$VivadoHome = [IO.Path]::GetFullPath($VivadoHome)
if (Test-Path -LiteralPath $Work) { throw 'Use a fresh Work directory' }
$tool = Join-Path $VivadoHome 'bin/vivado.bat'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'Missing explicit Vivado tool' }
if (-not (Test-Path -LiteralPath $AdiLibrary -PathType Container)) { throw 'Selected ADI library missing' }
$xprs = @(Get-ChildItem -LiteralPath $BdProject -Filter '*.xpr' -File)
$srcs = @(Get-ChildItem -LiteralPath $BdProject -Filter '*.srcs' -Directory)
if ($xprs.Count -ne 1 -or $srcs.Count -ne 1) { throw 'BD project needs exactly one XPR and one .srcs' }
$compare = Join-Path $PSScriptRoot 'compare_bd_state.py'
if ($PreflightOnly) {
    [pscustomobject]@{status='OUTPUTS_PREFLIGHT_PASS';eda_executed=$false;bd_project=$BdProject;adi_library=$AdiLibrary} | ConvertTo-Json
    exit 0
}
$free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
if ($free -lt $MinFreeGiB) { throw "Output generation needs $MinFreeGiB GiB free; available $([math]::Round($free,2)) GiB" }
if (Get-Process vivado,xelab,xsim -ErrorAction SilentlyContinue) { throw 'Another EDA process is running' }
New-Item -ItemType Directory -Path $Work | Out-Null
$project = Join-Path $Work 'project'
New-Item -ItemType Directory -Path $project | Out-Null
Copy-Item -LiteralPath $xprs[0].FullName -Destination $project
Copy-Item -LiteralPath $srcs[0].FullName -Destination $project -Recurse
foreach ($name in 'generate_platform_outputs.tcl','validate_platform_bd.tcl') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $Work $name)
}
$timer = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1; $nativeExit = $null; $copyGate = $null; $finalGate = $null
$peak = 0; $minFree = $free; $samples = 0
try {
    & python -B $compare --reference $BdProject --candidate $project --out "$Work/state_copy.json"
    $copyGate = $LASTEXITCODE
    if ($copyGate -ne 0) { throw "Copied project differs from accepted BD state (exit $copyGate)" }
    $xpr = Join-Path $project $xprs[0].Name
    $cmd = "/d /c `"`"$tool`" -mode batch -notrace -source `"$Work/generate_platform_outputs.tcl`" -log `"$Work/vivado.log`" -journal `"$Work/vivado.jou`" -tclargs `"$xpr`" `"$AdiLibrary`" `"$Work/receipt`" > `"$Work/console.log`" 2>&1`""
    $cmd | Set-Content -LiteralPath "$Work/invocation.txt" -Encoding UTF8
    $proc = Start-Process -FilePath "$env:ComSpec" -ArgumentList $cmd -WorkingDirectory $Work -WindowStyle Hidden -PassThru
    $null = $proc.Handle
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 2
        $samples++
        $ws = (Get-Process vivado -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
        if ($ws -gt $peak) { $peak = $ws }
        $f = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
        if ($f -lt $minFree) { $minFree = $f }
    }
    $proc.WaitForExit()
    $nativeExit = $proc.ExitCode
    if ($nativeExit -ne 0) { throw "Native batch exit $nativeExit" }
    $result = Get-Content -LiteralPath "$Work/receipt/native_result.json" -Raw | ConvertFrom-Json
    if ($result.status -cne 'FULL_BD_OUTPUT_GENERATION_COMPLETE') { throw 'Missing successful native result' }
    & python -B $compare --reference $BdProject --candidate $project --out "$Work/state_after.json"
    $finalGate = $LASTEXITCODE
    if ($finalGate -ne 0) { throw "Saved project differs from accepted BD state (exit $finalGate)" }
    $exitCode = 0
} catch {
    $_ | Out-String | Add-Content -LiteralPath "$Work/error.txt"
    Write-Output $_
} finally {
    [pscustomobject]@{exit_code=$exitCode;native_exit=$nativeExit;copy_state_gate_exit=$copyGate;final_state_gate_exit=$finalGate;
        elapsed_seconds=$timer.Elapsed.TotalSeconds;free_gib_at_start=$free;min_free_gib_observed=$minFree;
        vivado_peak_working_set_gib=[math]::Round($peak/1GB,3);memory_samples=$samples;
        bd_project=$BdProject;adi_library=$AdiLibrary;vivado_home=$VivadoHome;scope='full_BD_output_generation_only'} |
        ConvertTo-Json | Set-Content -LiteralPath "$Work/exit.json" -Encoding UTF8
}
exit $exitCode

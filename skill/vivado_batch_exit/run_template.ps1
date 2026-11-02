# Template: run one Vivado batch Tcl with a true exit code, a result-file check,
# memory sampling and an exit receipt written even on failure.
param(
    [Parameter(Mandatory)][string]$VivadoHome,   # e.g. D:\Xilinx\Vivado\2023.2 ; never rely on PATH
    [Parameter(Mandatory)][string]$Script,       # Tcl ending in: if {[catch {main} m]} {exit 1}; exit 0
    [Parameter(Mandatory)][string]$Work,         # must not exist yet
    [string]$ResultFile = 'native_result.json',  # written by the Tcl as its last step
    [double]$MinFreeGiB = 3.0,
    [string[]]$TclArgs = @()
)
$ErrorActionPreference = 'Stop'
$Work = [IO.Path]::GetFullPath($Work)
if (Test-Path -LiteralPath $Work) { throw 'Use a fresh Work directory' }
$tool = Join-Path $VivadoHome 'bin/vivado.bat'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'Missing explicit Vivado tool' }
$free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
if ($free -lt $MinFreeGiB) { throw "Need $MinFreeGiB GiB free; available $([math]::Round($free,2))" }
if (Get-Process vivado,xelab,xsim -ErrorAction SilentlyContinue) { throw 'Another EDA process is running' }
New-Item -ItemType Directory -Path $Work | Out-Null
$timer = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1; $nativeExit = $null; $peak = 0
try {
    $quoted = ($TclArgs | ForEach-Object { "`"$_`"" }) -join ' '
    $cmd = "/d /c `"`"$tool`" -mode batch -notrace -source `"$Script`" -log `"$Work/vivado.log`" -journal `"$Work/vivado.jou`" -tclargs $quoted > `"$Work/console.log`" 2>&1`""
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $cmd -WorkingDirectory $Work -WindowStyle Hidden -PassThru
    $null = $proc.Handle                      # keep the handle so ExitCode is available later
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 2
        $ws = (Get-Process vivado -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
        if ($ws -gt $peak) { $peak = $ws }
    }
    $proc.WaitForExit()
    $nativeExit = $proc.ExitCode
    if ($nativeExit -ne 0) { throw "Native batch exit $nativeExit" }
    if (-not (Test-Path -LiteralPath (Join-Path $Work $ResultFile))) { throw 'Exit 0 but result file missing' }
    $exitCode = 0
} catch {
    $_ | Out-String | Add-Content -LiteralPath "$Work/error.txt"
    Write-Output $_
} finally {
    [pscustomobject]@{exit_code=$exitCode; native_exit=$nativeExit; elapsed_seconds=$timer.Elapsed.TotalSeconds;
        free_gib_at_start=$free; vivado_peak_working_set_gib=[math]::Round($peak/1GB,3)} |
        ConvertTo-Json | Set-Content -LiteralPath "$Work/exit.json" -Encoding UTF8
}
exit $exitCode

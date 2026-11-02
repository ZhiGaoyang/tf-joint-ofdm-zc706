# Unit simulations of the NC metric block (rtl/ofdm_nc/rxs/ofdm_rxs_cmetric.v):
#   1. randomised stimulus with directed clear/counter coincidences against the fixed-point
#      reference (scripts/rtl/nc_cmetric_vectors.py, tests/rtl/ofdm_nc/tb_nc_cmetric.sv)
#   2. read cancel after a requester timeout (tests/rtl/ofdm_nc/tb_nc_cmetric_cancel.sv)
# Fresh <Work>; exit 0 only if both print their PASS marker with simulator exit 0.
param(
    [Parameter(Mandatory = $true)][string]$Work,
    [string]$VivadoHome = 'D:\Xilinx\Vivado\2023.2'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Work = [IO.Path]::GetFullPath($Work)
if (Test-Path -LiteralPath $Work) { throw 'Use a fresh Work directory' }
$bin = Join-Path $VivadoHome 'bin'
$dut = [IO.Path]::GetFullPath((Join-Path $root '..\src\rtl\ofdm\rxs\ofdm_rxs_cmetric.v'))
New-Item -ItemType Directory $Work | Out-Null
$rows = [Collections.Generic.List[object]]::new()
$result = 1
function Invoke-Tool([string]$Dir, [string]$Name, [string]$ToolArgs, [string]$Log) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $Dir
    try { & cmd /c "`"$bin\$Name.bat`" $ToolArgs > `"$Log`" 2>&1"; $code = $LASTEXITCODE } finally { Pop-Location }
    $rows.Add([pscustomobject]@{stage="$Dir\$Log";exit_code=$code;seconds=$sw.Elapsed.TotalSeconds})
    if ($code -ne 0) { throw "$Name failed (exit $code), see $Dir\$Log" }
}
try {
    # 1. randomised + directed vectors
    $d1 = Join-Path $Work 'cmetric'
    & python -I -B (Join-Path $root 'scripts\rtl\nc_cmetric_vectors.py') (Join-Path $d1 'vec')
    if ($LASTEXITCODE -ne 0) { throw 'vector generation failed' }
    Copy-Item (Join-Path $d1 'vec\*.mem') $d1
    $info = Get-Content (Join-Path $d1 'vec\info.json') -Raw | ConvertFrom-Json
    Invoke-Tool $d1 'xvlog' "--work work `"$dut`"" 'design.log'
    Invoke-Tool $d1 'xvlog' "--sv --work work `"$(Join-Path $root 'tests\rtl\ofdm_nc\tb_nc_cmetric.sv')`"" 'bench.log'
    Invoke-Tool $d1 'xelab' '--relax --snapshot cm work.tb_nc_cmetric' 'elab.log'
    Invoke-Tool $d1 'xsim' "cm -R -testplusarg `"CYCLES=$($info.cycles)`" -testplusarg `"READS=$($info.reads)`"" 'sim.log'
    $ok1 = (Get-Content (Join-Path $d1 'sim.log') -Raw) -match '(?m)^CMETRIC_PASS '
    # 2. read cancel
    $d2 = Join-Path $Work 'cancel'
    New-Item -ItemType Directory $d2 | Out-Null
    Invoke-Tool $d2 'xvlog' "--work work `"$dut`"" 'design.log'
    Invoke-Tool $d2 'xvlog' "--sv --work work -d HAS_CANCEL `"$(Join-Path $root 'tests\rtl\ofdm_nc\tb_nc_cmetric_cancel.sv')`"" 'bench.log'
    Invoke-Tool $d2 'xelab' '--relax --snapshot cc work.tb_nc_cmetric_cancel' 'elab.log'
    Invoke-Tool $d2 'xsim' 'cc -R' 'sim.log'
    $ok2 = (Get-Content (Join-Path $d2 'sim.log') -Raw) -match '(?m)^CANCEL_PASS'
    "cmetric_vectors pass=$ok1; cancel pass=$ok2"
    if ($ok1 -and $ok2) { $result = 0; 'ALL_PASS' } else { 'FAILED' }
} catch {
    $_ | Out-String | Set-Content (Join-Path $Work 'failure.txt') -Encoding UTF8
    Write-Output $_
} finally {
    ConvertTo-Json -InputObject @($rows.ToArray()) | Set-Content (Join-Path $Work 'stages.json') -Encoding UTF8
    [pscustomobject]@{result=$(if ($result -eq 0) {'PASS'} else {'FAIL'});exit_code=$result} | ConvertTo-Json |
        Set-Content (Join-Path $Work 'result.json') -Encoding UTF8
}
exit $result

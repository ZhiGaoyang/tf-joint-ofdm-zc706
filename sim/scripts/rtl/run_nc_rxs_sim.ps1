# Host simulation of the NC streaming RX core (rtl/ofdm_nc decode/core over the
# accepted rtl/ofdm modules, real xfft 9.1 behavioural model).  Compiles once
# into a fresh <Work>, runs the scenarios of each vector directory (produced by
# scripts/model/nc_rxs_vectors.py or the accepted scripts/model/rxs_vectors.py)
# and checks every log with scripts/model/nc_rxs_check.py.  Exit 0 only if all pass.
param(
    [Parameter(Mandatory = $true)][string]$Work,
    [Parameter(Mandatory = $true)][string[]]$Vectors,
    [string[]]$Scenarios = @(),
    [int]$Backoff = 10,
    [string]$VivadoHome = 'D:\Xilinx\Vivado\2023.2'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Work = [IO.Path]::GetFullPath($Work)
if (Test-Path -LiteralPath $Work) { throw 'Use a fresh Work directory' }
$bin = Join-Path $VivadoHome 'bin'
$ip = [IO.Path]::GetFullPath((Join-Path $root '..\src\ip\sim'))     # FFT/IFFT behavioural models + glbl.v (src/ip/README.md)
$rtl = [IO.Path]::GetFullPath((Join-Path $root '..\src\rtl\ofdm'))
$ini = if (Test-Path (Join-Path $ip 'xsim.ini')) { Join-Path $ip 'xsim.ini' } else { Join-Path $VivadoHome 'data\xsim\xsim.ini' }
$ncd = $rtl                           # single flattened RTL tree
New-Item -ItemType Directory $Work | Out-Null
$env:PYTHONPATH = $root
$rows = [Collections.Generic.List[object]]::new()
$result = 1
Push-Location $Work
try {
    function Invoke-Tool([string]$Name, [string[]]$ToolArgs, [string]$Log) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & cmd /c "`"$bin\$Name.bat`" $($ToolArgs -join ' ') > `"$Log`" 2>&1"
        $code = $LASTEXITCODE
        $rows.Add([pscustomobject]@{stage=$Log;exit_code=$code;seconds=$sw.Elapsed.TotalSeconds})
        if ($code -ne 0) { throw "$Name failed (exit $code), see $Log" }
    }
    Copy-Item $ini xsim.ini -Force
    Copy-Item (Join-Path $rtl 'phy\ofdm_cfo_sine_quarter.mem') . -Force
    $accepted = @('phy\ofdm_rx_metric_registered.v', 'phy\ofdm_rx_equalize.v', 'phy\ofdm_rx_cpe_phase.v',
        'rxs\ofdm_rxs_dcblock.v', 'rxs\ofdm_rxs_ring.v', 'rxs\ofdm_rxs_detect.v', 'rxs\ofdm_rxs_fetch.v',
        'rxs\ofdm_rxs_fft.v', 'rxs\ofdm_rxs_coeff.v', 'rxs\ofdm_rxs_chan.v', 'rxs\ofdm_rxs_cpe.v') |
        ForEach-Object { Join-Path $rtl $_ }
    $design = $accepted + @((Join-Path $ncd 'rxs\ofdm_rxs_cmetric.v'), (Join-Path $ncd 'rxs\ofdm_rxs_decode.v'), (Join-Path $ncd 'rxs\ofdm_rxs_core.v'))
    $bench = Join-Path $root 'tests\rtl\ofdm_nc\tb_nc_rxs_core.sv'
    $design + @($bench, "$ncd\phy\ofdm_nc_map.vh") | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} } |
        ConvertTo-Json | Set-Content sources.json -Encoding UTF8
    $q = $design | ForEach-Object { "`"$_`"" }
    Invoke-Tool 'xvhdl' @('--work', 'xil_defaultlib', "`"$ip\fft128.vhd`"") 'xvhdl.out'
    Invoke-Tool 'xvlog' (@('--work', 'xil_defaultlib', '-i', "`"$ncd\phy`"", '-i', "`"$rtl\phy`"", "`"$ip\glbl.v`"") + $q) 'xvlog.out'
    Invoke-Tool 'xvlog' @('--sv', '--work', 'xil_defaultlib', "`"$bench`"") 'xvlog_tb.out'
    $libs = 'xbip_utils_v3_0_11 axi_utils_v2_0_7 c_reg_fd_v12_0_7 xbip_dsp48_wrapper_v3_0_5 xbip_pipe_v3_0_7 xbip_dsp48_addsub_v3_0_7 xbip_addsub_v3_0_7 c_addsub_v12_0_16 c_mux_bit_v12_0_7 c_shift_ram_v12_0_15 xbip_bram18k_v3_0_7 mult_gen_v12_0_19 cmpy_v6_0_22 floating_point_v7_0_21 xfft_v9_1_10 unisims_ver unimacro_ver secureip xpm'
    $elab = @('--relax', '--mt', '2', '-L', 'xil_defaultlib') + (($libs -split ' ') | ForEach-Object { @('-L', $_) }) +
        @('--snapshot', 'nc_rxs', 'xil_defaultlib.tb_nc_rxs_core', 'xil_defaultlib.glbl')
    Invoke-Tool 'xelab' $elab 'xelab.out'
    $failed = @()
    foreach ($vec in $Vectors) {
        $vec = [IO.Path]::GetFullPath($vec)
        $index = Get-Content (Join-Path $vec 'index.json') -Raw | ConvertFrom-Json
        $names = if ($Scenarios.Count) { @($Scenarios | Where-Object { $index.PSObject.Properties.Name -contains $_ }) } else { @($index.PSObject.Properties.Name) }
        foreach ($name in $names) {
            $entry = $index.$name
            $dir = Join-Path $vec $name
            $log = Join-Path $Work "$name.log"
            $blind = if ($null -ne $entry.blind) { $entry.blind } else { 1 }
            $thr = if ($null -ne $entry.hdrthr) { $entry.hdrthr } else { 185360 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $plus = "-testplusarg `"STREAM=$($dir -replace '\\','/')/stream.mem`" -testplusarg `"NSAMP=$($entry.nsamp)`" -testplusarg `"GAIN=$($entry.gain)`" -testplusarg `"BLIND=$blind`" -testplusarg `"HDRTHR=$thr`" -testplusarg `"BACKOFF=$Backoff`""
            & cmd /c "`"$bin\xsim.bat`" nc_rxs -R $plus > `"$log`" 2>&1"
            $simExit = $LASTEXITCODE
            $check = & python -m scripts.model.nc_rxs_check (Join-Path $dir 'expected.json') $log
            $checkExit = $LASTEXITCODE
            $rows.Add([pscustomobject]@{stage=$name;exit_code=$simExit;check_exit=$checkExit;seconds=$sw.Elapsed.TotalSeconds;check=($check -join ' ')})
            "{0,-14} sim_exit={1} check_exit={2} {3:N1}s {4}" -f $name, $simExit, $checkExit, $sw.Elapsed.TotalSeconds, ($check -join ' ')
            if ($simExit -ne 0 -or $checkExit -ne 0) { $failed += $name }
        }
    }
    if ($failed.Count) { Write-Output "FAILED: $($failed -join ', ')" } else { Write-Output 'ALL_PASS'; $result = 0 }
} catch {
    $_ | Out-String | Set-Content failure.txt -Encoding UTF8
    Write-Output $_
} finally {
    ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 3 | Set-Content stages.json -Encoding UTF8
    [pscustomobject]@{result=$(if ($result -eq 0) {'PASS'} else {'FAIL'});exit_code=$result} | ConvertTo-Json | Set-Content result.json -Encoding UTF8
    Pop-Location
}
exit $result

# Host TX->RX digital loopback of the NC design: rtl/ofdm_nc framer/loader/grid/
# frame chain and decode/core over the accepted rtl/ofdm modules, real IFFT/FFT
# behavioural models.  Fresh <Work>; compiles once, then runs each case
#   "frames,len,mcs,bursts,mask,mask2,backoff,tone_bin,tone_amp"
# Exit 0 only if every case prints RXL_PASS with sim exit 0 and no fault.
param(
    [Parameter(Mandatory = $true)][string]$Work,
    [string[]]$Cases = @('4,256,0,2,0,0,10,0,0'),
    [int]$Timeout = 400000,
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
        'rxs\ofdm_rxs_fft.v', 'rxs\ofdm_rxs_coeff.v', 'rxs\ofdm_rxs_chan.v', 'rxs\ofdm_rxs_cpe.v',
        'phy\ofdm_ifft_stream.v', 'phy\ofdm_cp_insert.v', 'phy\ofdm_training_mux.v',
        'txs\ofdm_tx_mapper_v2.v', 'txs\ofdm_tx_prbs_source.v') | ForEach-Object { Join-Path $rtl $_ }
    $nc = @('rxs\ofdm_rxs_cmetric.v', 'rxs\ofdm_rxs_decode.v', 'rxs\ofdm_rxs_core.v', 'phy\ofdm_carrier_loader.v',
        'txs\ofdm_tx_framer_v2.v', 'txs\ofdm_frame_grid_v2.v', 'txs\ofdm_tx_frame_v2.v') | ForEach-Object { Join-Path $ncd $_ }
    $design = $accepted + $nc
    $bench = Join-Path $root 'tests\rtl\ofdm_nc\tb_nc_txrx_loop.sv'
    $design + @($bench, "$ncd\phy\ofdm_nc_map.vh") | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} } |
        ConvertTo-Json | Set-Content sources.json -Encoding UTF8
    $q = $design | ForEach-Object { "`"$_`"" }
    Invoke-Tool 'xvhdl' @('--work', 'xil_defaultlib', "`"$ip\fft128.vhd`"", "`"$ip\ifft128.vhd`"") 'xvhdl.out'
    Invoke-Tool 'xvlog' (@('--work', 'xil_defaultlib', '-i', "`"$ncd\phy`"", '-i', "`"$rtl\phy`"", "`"$ip\glbl.v`"") + $q) 'xvlog.out'
    Invoke-Tool 'xvlog' @('--sv', '--work', 'xil_defaultlib', "`"$bench`"") 'xvlog_tb.out'
    $libs = 'xbip_utils_v3_0_11 axi_utils_v2_0_7 c_reg_fd_v12_0_7 xbip_dsp48_wrapper_v3_0_5 xbip_pipe_v3_0_7 xbip_dsp48_addsub_v3_0_7 xbip_addsub_v3_0_7 c_addsub_v12_0_16 c_mux_bit_v12_0_7 c_shift_ram_v12_0_15 xbip_bram18k_v3_0_7 mult_gen_v12_0_19 cmpy_v6_0_22 floating_point_v7_0_21 xfft_v9_1_10 unisims_ver unimacro_ver secureip xpm'
    $elab = @('--relax', '--mt', '2', '-L', 'xil_defaultlib') + (($libs -split ' ') | ForEach-Object { @('-L', $_) }) +
        @('--snapshot', 'nc_loop', 'xil_defaultlib.tb_nc_txrx_loop', 'xil_defaultlib.glbl')
    Invoke-Tool 'xelab' $elab 'xelab.out'
    $failed = @()
    foreach ($case in $Cases) {
        $f = $case -split ','
        if ($f.Count -ne 9) { throw "case needs 9 fields: $case" }
        $name = "f$($f[0])_l$($f[1])_m$($f[2])_b$($f[3])_k$($f[4])_$($f[5])_o$($f[6])_t$($f[7])_$($f[8])"
        $log = Join-Path $Work "$name.log"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $plus = (@('FRAMES','LEN','MCS','BURSTS','MASK','MASK2','BACKOFF','TONE_BIN','TONE_AMP') |
            ForEach-Object -Begin { $i = 0 } -Process { "-testplusarg `"$_=$($f[$i])`""; $i++ }) -join ' '
        $plus += " -testplusarg `"TIMEOUT=$Timeout`""
        & cmd /c "`"$bin\xsim.bat`" nc_loop -R $plus > `"$log`" 2>&1"
        $simExit = $LASTEXITCODE
        $text = Get-Content $log -Raw
        $res = ([regex]::Match($text, 'RXL_RESULT[^\r\n]*')).Value
        $pass = $simExit -eq 0 -and $text -match '(?m)^RXL_PASS' -and $text -notmatch 'RXL_FAULT'
        $rows.Add([pscustomobject]@{stage=$name;exit_code=$simExit;pass=$pass;seconds=$sw.Elapsed.TotalSeconds;result=$res})
        "{0,-40} sim_exit={1} pass={2} {3:N1}s {4}" -f $name, $simExit, $pass, $sw.Elapsed.TotalSeconds, $res
        if (-not $pass) { $failed += $name }
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

# Platform-level host test of the NC lean development core: rtl/ofdm_nc core,
# frame chain and RX over the accepted rtl/ofdm modules; AXI-Lite, real TX
# prefill/CDC, real RX adapter CDC.  Fresh <Work>; exit 0 only on LEAN_PASS.
param(
    [Parameter(Mandatory = $true)][string]$Work,
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
    $all = @('phy\ofdm_rx_metric_registered.v', 'phy\ofdm_rx_equalize.v', 'phy\ofdm_rx_cpe_phase.v',
        'rxs\ofdm_rxs_dcblock.v', 'rxs\ofdm_rxs_ring.v', 'rxs\ofdm_rxs_detect.v', 'rxs\ofdm_rxs_fetch.v',
        'rxs\ofdm_rxs_fft.v', 'rxs\ofdm_rxs_coeff.v', 'rxs\ofdm_rxs_chan.v', 'rxs\ofdm_rxs_cpe.v',
        'rxs\ofdm_rxs_cmetric.v', 'rxs\ofdm_rxs_decode.v', 'rxs\ofdm_rxs_core.v',
        'phy\ofdm_ifft_stream.v', 'phy\ofdm_cp_insert.v', 'phy\ofdm_carrier_loader.v', 'phy\ofdm_training_mux.v',
        'txs\ofdm_tx_framer_v2.v', 'txs\ofdm_tx_mapper_v2.v', 'txs\ofdm_frame_grid_v2.v', 'txs\ofdm_tx_frame_v2.v',
        'txs\ofdm_tx_prbs_source.v', 'txs\ofdm_tx_rf_frame_v2.v',
        'interfaces\ofdm_async_fifo.v', 'interfaces\ofdm_tx_adapter.v', 'interfaces\ofdm_tx_prefill.v',
        'interfaces\ofdm_rx_adapter.v', 'lean\ofdm_development_core.v')
    $design = $all | ForEach-Object { if (Test-Path (Join-Path $ncd $_)) { Join-Path $ncd $_ } else { Join-Path $rtl $_ } }
    $bench = Join-Path $root 'tests\rtl\ofdm_nc\tb_nc_lean_core.sv'
    $design + @($bench, "$ncd\phy\ofdm_nc_map.vh") | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} } |
        ConvertTo-Json | Set-Content sources.json -Encoding UTF8
    $q = $design | ForEach-Object { "`"$_`"" }
    Invoke-Tool 'xvhdl' @('--work', 'xil_defaultlib', "`"$ip\fft128.vhd`"", "`"$ip\ifft128.vhd`"") 'xvhdl.out'
    Invoke-Tool 'xvlog' (@('--work', 'xil_defaultlib', '-i', "`"$ncd\phy`"", '-i', "`"$rtl\phy`"", "`"$ip\glbl.v`"") + $q) 'xvlog.out'
    $xpm = Join-Path $VivadoHome 'data\ip\xpm'
    Invoke-Tool 'xvlog' @('--sv', '--work', 'xil_defaultlib', "`"$xpm\xpm_cdc\hdl\xpm_cdc.sv`"", "`"$xpm\xpm_memory\hdl\xpm_memory.sv`"", "`"$xpm\xpm_fifo\hdl\xpm_fifo.sv`"", "`"$bench`"") 'xvlog_tb.out'
    $libs = 'xbip_utils_v3_0_11 axi_utils_v2_0_7 c_reg_fd_v12_0_7 xbip_dsp48_wrapper_v3_0_5 xbip_pipe_v3_0_7 xbip_dsp48_addsub_v3_0_7 xbip_addsub_v3_0_7 c_addsub_v12_0_16 c_mux_bit_v12_0_7 c_shift_ram_v12_0_15 xbip_bram18k_v3_0_7 mult_gen_v12_0_19 cmpy_v6_0_22 floating_point_v7_0_21 xfft_v9_1_10 unisims_ver unimacro_ver secureip'
    $elab = @('--relax', '--mt', '2', '-L', 'xil_defaultlib') + (($libs -split ' ') | ForEach-Object { @('-L', $_) }) +
        @('--snapshot', 'nc_lean', 'xil_defaultlib.tb_nc_lean_core', 'xil_defaultlib.glbl')
    Invoke-Tool 'xelab' $elab 'xelab.out'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & cmd /c "`"$bin\xsim.bat`" nc_lean -R > lean.log 2>&1"
    $simExit = $LASTEXITCODE
    $text = Get-Content lean.log -Raw
    $rows.Add([pscustomobject]@{stage='simulate';exit_code=$simExit;seconds=$sw.Elapsed.TotalSeconds})
    ([regex]::Matches($text, '(?m)^LEAN_[^\r\n]*') | ForEach-Object { $_.Value }) -join "`n"
    "sim_exit={0} {1:N1}s" -f $simExit, $sw.Elapsed.TotalSeconds
    if ($simExit -eq 0 -and $text -match '(?m)^LEAN_PASS') { $result = 0 }
} catch {
    $_ | Out-String | Set-Content failure.txt -Encoding UTF8
    Write-Output $_
} finally {
    ConvertTo-Json -InputObject @($rows.ToArray()) | Set-Content stages.json -Encoding UTF8
    [pscustomobject]@{result=$(if ($result -eq 0) {'PASS'} else {'FAIL'});exit_code=$result} | ConvertTo-Json | Set-Content result.json -Encoding UTF8
    Pop-Location
}
exit $result

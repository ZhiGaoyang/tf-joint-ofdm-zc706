# NC frame-grid unit simulation (design B, TX).  Fresh -Work directory required.
#   -Rtl accepted : rtl/ofdm grid, mask-0 vectors (bench/vector self-check)
#   -Rtl nc       : rtl/ofdm_nc framer/loader/grid over rtl/ofdm mapper/training mux
param(
    [Parameter(Mandatory)][string]$Work,
    [ValidateSet('accepted','nc')][string]$Rtl = 'nc',
    [string]$VivadoHome = 'D:\Xilinx\Vivado\2023.2'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$Work = [IO.Path]::GetFullPath($Work)
if (Test-Path -LiteralPath $Work) { throw 'Use a fresh Work directory' }
$bin = Join-Path $VivadoHome 'bin'
$acc = [IO.Path]::GetFullPath((Join-Path $root '../src/rtl/ofdm'))
$ncd = $acc                           # single flattened RTL tree
New-Item -ItemType Directory -Path $Work | Out-Null
$receipts = [Collections.Generic.List[object]]::new()
$result = 1
Push-Location $Work
try {
    function Invoke-Stage([string]$Exe, [string[]]$ToolArgs, [string]$Tag) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Exe @ToolArgs *> "$Tag.log"
        $code = $LASTEXITCODE
        $receipts.Add([pscustomobject]@{stage=$Tag;exit_code=$code;seconds=$sw.Elapsed.TotalSeconds})
        ConvertTo-Json -InputObject @($receipts.ToArray()) | Set-Content stages.json -Encoding UTF8
        if ($code -ne 0) { throw "$Tag exit $code" }
    }
    $vecArgs = @('-I','-B',"$root/scripts/rtl/nc_grid_vectors.py","$Work/vec")
    if ($Rtl -eq 'accepted') { $vecArgs += '--mask0-only' }
    Invoke-Stage 'python' $vecArgs vectors
    Copy-Item "$Work/vec/vectors.mem" vectors.mem
    $common = @("$acc/txs/ofdm_tx_mapper_v2.v", "$acc/phy/ofdm_training_mux.v")
    if ($Rtl -eq 'nc') {
        $design = @("$ncd/txs/ofdm_tx_framer_v2.v", "$ncd/phy/ofdm_carrier_loader.v", "$ncd/txs/ofdm_frame_grid_v2.v") + $common
        $define = @('-d','NC_MASK_PORT')
        $inc = @('-i',"$ncd/phy")
    } else {
        $design = @("$acc/txs/ofdm_tx_framer_v2.v", "$acc/phy/ofdm_carrier_loader.v", "$acc/txs/ofdm_frame_grid_v2.v") + $common
        $define = @(); $inc = @()
    }
    $bench = "$root/tests/rtl/ofdm_nc/tb_nc_grid.sv"
    $design + @($bench) | ForEach-Object { [pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} } |
        ConvertTo-Json | Set-Content sources.json -Encoding UTF8
    Invoke-Stage "$bin/xvlog.bat" (@('--work','work') + $inc + $design) design
    Invoke-Stage "$bin/xvlog.bat" (@('--sv','--work','work') + $define + @($bench)) bench
    Invoke-Stage "$bin/xelab.bat" @('--relax','--snapshot','nc_grid','work.tb_nc_grid') elaborate
    Invoke-Stage "$bin/xsim.bat" @('nc_grid','-R') simulate
    $log = Get-Content simulate.log -Raw
    if ($log -notmatch '(?m)^NC_GRID_PASS ' -or $log -match '(?m)^(Fatal|ERROR):') { throw 'NC_GRID_PASS marker missing' }
    $result = 0
} catch {
    $_ | Out-String | Set-Content failure.txt -Encoding UTF8
    Write-Output $_
} finally {
    [pscustomobject]@{rtl=$Rtl;result=$(if ($result -eq 0) {'PASS'} else {'FAIL'});exit_code=$result} |
        ConvertTo-Json | Set-Content result.json -Encoding UTF8
    Pop-Location
}
exit $result

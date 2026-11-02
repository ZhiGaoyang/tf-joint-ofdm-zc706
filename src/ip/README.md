# FFT / IFFT IP

The core uses two AMD Fast Fourier Transform v9.1 (LogiCORE) instances: `fft128` (receiver, forward) and
`ifft128` (transmitter, inverse).  This directory contains their configuration (`*.xci`) and the black-box
interface stubs used by `build/core_synth.tcl`.  The generated netlists and behavioural simulation models are
AMD tool output and are **not** redistributed here; they are included in the Vivado package submitted to the
contest organisers, from which the board image was rebuilt bit for bit.

| File expected by the scripts | Used by | How to obtain it yourself (Vivado 2023.2) |
|---|---|---|
| `src/ip/fft/fft128_edif/fft128/fft128.edn` | `build/core_synth.tcl` | open `src/ip/fft/fft128.xci` in a project for xc7z045ffg900-2, generate output products (out-of-context synthesis), open the IP synthesis checkpoint and `write_edif -security_mode all` to this path |
| `src/ip/ifft/ifft_core.edf` | `build/core_synth.tcl` | same for `src/ip/ifft/ifft128.xci` |
| `src/ip/sim/fft128.vhd`, `src/ip/sim/ifft128.vhd` | `sim/scripts/rtl/run_nc_*_sim.ps1` | generate the simulation output products of the two `.xci` files (behavioural VHDL wrappers) |
| `src/ip/sim/glbl.v` | `sim/scripts/rtl/run_nc_*_sim.ps1` | copy `data/verilog/src/glbl.v` from the Vivado installation |

Netlists regenerated from the `.xci` files have the same configuration but have not been compared bit for bit
with the netlists used for the board image.  These paths are listed in `.gitignore`.

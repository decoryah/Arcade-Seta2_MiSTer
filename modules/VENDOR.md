# Vendored modules

Third-party HDL copied into the tree (no submodules); each keeps its own licence.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k | Jorge Cwik's fx68k | the owner's crospang-mister | GPL-3.0 |
| x1_010 | https://github.com/ppriest/Arcade-Seta_MiSTer @ 208dc11035f3c9356c5c1005c0005aad14e51239 (MAME's `x1_010.cpp` transcribed) | | GPL-3.0 (the repository's README: "GPL v3"; its LICENSE file, copied here, is the GPL v2 text, "or any later version") |
| crt_adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`; one local fix, below) | rmonic79 (Umberto Parisi), with Andrea Bogazzi (asturur); the copy of the owner's Monster Maulers and Heavy Unit cores | GPL-3.0 or later |

## Local changes

`x1_010/x1_010.sv`: the key-on state takes the registered write data (PLAN.md).

`crt_adjust/crt_adjust.sv`, one line, `hoff_s`: the conditional mixes `$signed(hoffset)` with an unsigned replication, so by the
Verilog rules (and in Verilator) the result is unsigned and a negative H-Position is zero-extended (-1 becomes 511), which moves
the picture window out of the line and blanks the picture. The line sign-extends `hoffset` explicitly, which is what the module is
meant to do and gives the same result in every tool. Nothing else differs from upstream. (The Metro core's copy also gates the
picture with the vertical blank one line earlier, for Metro's stream, whose vertical blank changes before the line's horizontal
sync; seta2's changes at the sync, which is what upstream expects, so that change is not taken.)

The glue (`rtl/s2_crtadj.sv`) and its unit bench (`sim/crt/`) are this core's, after the Metro core's `rtl/metro_crtadj.sv`.

# Seta2 for MiSTer

FPGA core of Seta's "newer" arcade hardware (1994 - 2002: the TMP68301 CPU, the X1-020 / DX-101 video chip and the X1-010 sound chip), for the MiSTer. Written
from MAME 0.289's `seta/seta2.cpp`, `x1_020_dx_101.cpp`, `tmp68301.cpp`, `x1_010.cpp` and `eepromser.cpp`; MAME was the oracle for everything (ROM layout, video chip
state, pictures, sound, inputs, the battery RAM), and the result is checked against it in simulation and on a real MiSTer. No ROMs or other copyrighted data are in this
repository: you supply your own MAME 0.289 romsets.

## Three core files

One source tree builds three core files, one per board dot clock: each runs its machine at a whole multiple of its boards' dot clock, so every dot is the same number of
clocks and a direct video output (the RetroTINK 4K's DV1 mode) samples a clean picture.

| Core file | Machine clock | Games |
|---|---|---|
| `seta2_<date>.rbf` | 89.4588 MHz (8.13 MHz dots x 11) | Mobile Suit Gundam EX Revue, Wakakusamonogatari Mahjong Yonshimai, Kosodate Quiz My Angel 1 / 2, Puzzle De Bowling |
| `seta2grd_<date>.rbf` | 93.75 MHz (6.25 MHz dots x 15) | Guardians / Denjin Makai II (three boards) |
| `seta2pen_<date>.rbf` | 91 MHz (7 MHz dots x 13) | Penguin Brothers, Hong Tian Lei (A-Blast), and Sammy's light-gun games: Deer Hunting USA, Turkey Hunting USA, Wing Shooting Championship, Trophy Hunting - Bear & Moose |

The MRAs name the right core file, so you only have to put all three RBFs in `_Arcade/cores/` and the MRAs in `_Arcade/`. The standard 32 MB SDRAM module is enough for
every set (the graphics, up to 32 MB, are in the SDRAM; the program and the samples in the DDR3). Not supported, from the same driver: Reel'N Quake!, Endless Riches and
TelePachi Fever Lion (medal machines), and Star Audition, the A-Blast bootleg, Namco Stars and Balance Try (not working in MAME 0.289 either).

## Screenshots

The title screens, as MAME 0.289 draws them.

**`seta2`**

| | | |
|---|---|---|
| ![Mobile Suit Gundam EX Revue](docs/title_gundamex.png) | ![Wakakusamonogatari Mahjong Yonshimai](docs/title_mj4simai.png) | ![Kosodate Quiz My Angel](docs/title_myangel.png) |
| Mobile Suit Gundam EX Revue | Wakakusamonogatari Mahjong Yonshimai | Kosodate Quiz My Angel |
| ![Kosodate Quiz My Angel 2](docs/title_myangel2.png) | ![Puzzle De Bowling](docs/title_pzlbowl.png) |  |
| Kosodate Quiz My Angel 2 | Puzzle De Bowling |  |

**`seta2grd`**

| | | |
|---|---|---|
| ![Guardians](docs/title_grdians.png) |  |  |
| Guardians / Denjin Makai II |  |  |

**`seta2pen`**

| | | |
|---|---|---|
| ![Penguin Brothers](docs/title_penbros.png) | ![Deer Hunting USA](docs/title_deerhunt.png) | ![Turkey Hunting USA](docs/title_turkhunt.png) |
| Penguin Brothers | Deer Hunting USA | Turkey Hunting USA |
| ![Wing Shooting Championship](docs/title_wschamp.png) | ![Trophy Hunting - Bear & Moose](docs/title_trophyh.png) |  |
| Wing Shooting Championship | Trophy Hunting - Bear & Moose |  |

## Install

The zip of a GitHub release unpacks over the root of the SD card. By hand:

1. Put `releases/seta2_<date>.rbf`, `seta2grd_<date>.rbf` and `seta2pen_<date>.rbf` in `/media/fat/_Arcade/cores/` and the contents of `mra/` in `/media/fat/_Arcade/`
   (the other versions of a title are in `_alternatives/_<Title>/`). Keep the RBF names and dates: MiSTer finds the core by the MRA's `<rbf>` name and takes the newest.
   **Delete older `seta2*.rbf` files.**
2. Put your MAME 0.289 romsets in `/media/fat/games/mame/` (the merged set, or the split sets with their parent zip).
3. Start the game from the Arcade menu. With a recent Main_MiSTer the ROM image (up to 41 MB) loads in about a second (**fast loading**: the MRAs carry
   `address="0x30000000"`, which makes Main_MiSTer copy the whole image into the DDR3 at once, and the core copies the graphics from there into the SDRAM); an older
   Main_MiSTer ignores the attribute and streams the image as before, which takes longer. Use the MRAs of the same release as the cores.
4. **Buttons:** define them once per game ("Define buttons"); each MRA names the buttons its game uses (the others are `-`, which MiSTer skips).

### `seta2`

| MRA | Set | ROM zips (MAME 0.289) |
|---|---|---|
| Mobile Suit Gundam EX Revue | gundamex | gundamex |
| Wakakusamonogatari Mahjong Yonshimai | mj4simai | mj4simai |
| Kosodate Quiz My Angel | myangel | myangel |
| Kosodate Quiz My Angel 2 | myangel2 | myangel2 |
| Puzzle De Bowling | pzlbowl | pzlbowl |

### `seta2grd`

| MRA | Set | ROM zips (MAME 0.289) |
|---|---|---|
| Guardians (P-FG01-1 PCB) | grdians | grdians |
| &nbsp;&nbsp;Guardians (P0-113A PCB) | grdiansa | grdiansa + grdians |
| &nbsp;&nbsp;Guardians (bootleg) | grdiansbl | grdiansbl + grdians |

### `seta2pen`

| MRA | Set | ROM zips (MAME 0.289) |
|---|---|---|
| Penguin Brothers | penbros | penbros |
| &nbsp;&nbsp;Hong Tian Lei (A-Blast) | ablast | ablast + penbros |
| Deer Hunting USA (V4.3) | deerhunt | deerhunt |
| &nbsp;&nbsp;Deer Hunting USA (V4.2) | deerhunta | deerhunta + deerhunt |
| &nbsp;&nbsp;Deer Hunting USA (V4.0) | deerhuntb | deerhuntb + deerhunt |
| &nbsp;&nbsp;Deer Hunting USA (V3) | deerhuntc | deerhuntc + deerhunt |
| &nbsp;&nbsp;Deer Hunting USA (V2) | deerhuntd | deerhuntd + deerhunt |
| &nbsp;&nbsp;Deer Hunting USA (V1) | deerhunte | deerhunte + deerhunt |
| &nbsp;&nbsp;Deer Hunting USA (V4.4.1, Japan) | deerhuntj | deerhuntj + deerhunt |
| Turkey Hunting USA (V1.00) | turkhunt | turkhunt |
| Wing Shooting Championship (V2.00) | wschamp | wschamp |
| &nbsp;&nbsp;Wing Shooting Championship (V1.01) | wschampa | wschampa + wschamp |
| &nbsp;&nbsp;Wing Shooting Championship (V1.00) | wschampb | wschampb + wschamp |
| Trophy Hunting - Bear & Moose (V1.00) | trophyh | trophyh |
| &nbsp;&nbsp;Trophy Hunting - Bear & Moose (location test) | trophyht | trophyht + trophyh |

`tools/make_mra.py` writes the MRAs from MAME 0.289's ROM lists and DIP switches (read from `seta2.cpp` itself) and checks that each builds, byte for byte, the image the
simulations ran, with the md5 MiSTer computes.

## Controls

| | |
|---|---|
| Joystick | 8-way stick, Start, Coin and the game's buttons, named in its MRA as the games call them (Gundam EX and Puzzle De Bowling in their How To Play screens; the order checked by pressing each in MAME): see the table below. My Angel 1 / 2 have no joystick |
| Light guns | Deer Hunting, Turkey Hunting: one gun; Wing Shooting, Trophy Hunting: two (player 2 on the second controller). Aim with a gun that MiSTer sees as an analog stick, a mouse, or a gamepad's stick and d-pad: below |
| Keyboard | 1 / 2 start, 5 / 6 coin, 9 service (the service coin). Test modes: the Service Mode DIP switch, then Reset |
| Mahjong panel (Mahjong Yonshimai) | keyboard, MAME's defaults: letters A-N, Left Ctrl = Kan, Left Alt = Pon, Space = Chi, Left Shift = Reach, Z = Ron, 2 = Bet, Y = Flip Flop, Right Alt = Last Chance, Right Ctrl = Take Score, Right Shift = Double Up, Enter = Big, Backspace = Small |

| Game | A | B | X | Y |
|---|---|---|---|---|
| Guardians | Attack | Jump | Special (the power gauge's attack) | |
| Gundam EX | Soft Attack | Medium Attack | Hard Attack | Throw |
| My Angel 1 / 2 | Answer 1 | Answer 2 | Answer 3 | Answer 4 |
| Puzzle De Bowling | Left Curve | Throw (straight ball) | Right Curve | |
| Penguin Brothers, A-Blast | Bomb | Jump | | |
| Deer / Turkey Hunting, Wing Shooting, Trophy Hunting | Trigger | Pump | | |
| Trophy Hunting (location test) | Trigger | | | |

### Light guns

The games read where the gun points; the core makes that position from what MiSTer has, so no light gun is needed:

| | |
|---|---|
| A gun seen as an analog stick | Sinden, GUN4IR and the like, which MiSTer sees as a gamepad's left analog stick: the stick's position is the aim, -128..127 across the whole picture. Set **P1 stick** (P2 stick) to **Aim**; the gun's own calibration applies |
| Mouse | OSD **Mouse aims** (P1, the default, or P2): moves the aim; the left button is the trigger, the right the pump |
| Gamepad | the left analog stick aims as above; the d-pad moves the aim (2 steps of 256 across the picture per frame). With the stick on **Auto** (default) a stick pushed all the way (an arcade stick on a gamepad encoder) moves the aim as the d-pad does and a partial push aims directly; **D-pad** makes any push move the aim |
| Buttons | A (button 1) the trigger, B (button 2) the pump (the shotgun's reload; not needed with the DIP switch Gun Type on Hand Gun), Start, Coin. Trophy Hunting's location test has triggers only |
| Crosshair | OSD: shows where each gun points, red P1, green P2, as MAME's crosshair. A real gun does not need it |

The aim covers MAME's ranges (X 0x25-0xC5, Y 0x08-0xF8) evenly across the 320 x 240 picture, and the games take a shot where MAME's crosshair is: in Deer Hunting the
scene cards and the YES / rifle buttons answer to shots at their places on the screen. The games keep their bookkeeping, settings and records in a battery-backed RAM,
which the core saves to the SD card (OSD below).

## OSD options

| Option | Values | |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ | integer scaling on the HDMI scaler (the framework's video_freak; the 15 kHz analog output is not affected): the largest whole multiple of the picture's height that fits the screen, with the aspect ratio's width (V-Integer) or a whole multiple of the picture's width (Narrower: the multiple below the aspect ratio's width, HV-Integer+: the one above it while it fits, HV-Integer: the nearer). With Full Screen the integer modes use the screen's own proportions |
| Scandoubler Fx | None, HQ2x, CRT 25 / 50 / 75 % | the core's horizontal blank toggles on every line, the vertical blank's included, as the scandoubler needs |
| CRT Adjust (a page of its own) | Off / On, H-Size, H-Position, V-Shift | the size and place of the picture on a 15 kHz analog output without the monitor losing its lock, after rmonic79's [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) (`modules/crt_adjust`): H-Size -16..+15 (a step is 1/64 of the picture's width, about its centre), H-Position -48..+48 dots, V-Shift -16..+15 lines (positive moves it down). It does nothing while the scandoubler is in use and the HDMI picture follows it: leave it Off for HDMI and direct video (DV1). Each game's room is in the table below |
| Crosshair | Off, P1, P2, P1+P2 | the light-gun games only (Controls, Light guns) |
| P1 stick, P2 stick | Auto, Aim, D-pad | the light-gun games only |
| Mouse aims | P1, P2, Off | the light-gun games only |
| Autosave NVRAM | On, Off | the light-gun games only. On: when the OSD opens after the game has changed its battery RAM, MiSTer saves it to the SD card |
| Save NVRAM | | the same at once |
| DIP switches | per game | as MAME 0.289 defines them, with MAME's defaults; Gundam EX's Language jumper too. The light-gun games' second bank works here (in MAME 0.289 it does not reach the games) |
| Volume | Normal, -6 dB, -12 dB, -18 dB | Normal is MAME's mix (the X1-010's two outputs into one speaker) |
| Pause | Off, On | stops the CPU and the sound chip; the picture stays |
| Turbo CPU | Off, On | Guardians only: the 68000 at 23.44 MHz instead of 16.67 (16.27 on the P0-113A board and the bootleg), for less slowdown when the screen is busy |
| CPU speed | Native 16.27 MHz, Turbo 20.33 MHz, Turbo 22.36 MHz | Gundam EX only, the same. Only the 68000 runs faster: the sound chip, the TMP68301 timers (Guardians' music tempo) and the video keep the board's rates. The most is a quarter of the core file's clock: the 68000 (fx68k) is given two clocks for each of its steps and needs them (its longest path is 12.8 ns, a clock 10.7-11.2 ns) |
| Sync widths | Standard, Board | Standard (default) caps the horizontal sync at ~4.7 us and the vertical sync at 3 lines; Board gives them as the games program them (Guardians 7.5 us and 4 lines, Penguin Brothers / A-Blast 9.1 us), which some TVs show dark and unsteady |
| SDRAM read capture | Normal, Late | a diagnostic for SDRAM modules that answer late |
| Reset | | restarts the machine |

MiSTer keeps the battery RAM on the SD card as a `.nvm` file (the MRAs' `<nvram index="4" size="8192"/>`: its first 8 KB, all the games use) and loads it with the
game; the bytes are laid out as the start of MAME's `nvram/<set>/nvram`. Without a saved file the RAM starts cleared, as MAME's. Gundam EX's EEPROM starts from the MRA's
image at every load (its settings are not saved).

CRT Adjust's room in each game (beyond it the picture's edge is cut, or its first / last lines fall into the vertical sync):

| Game | H-Size about the centre | H-Position | V-Shift |
|---|---|---|---|
| Guardians | up to +6 | -59..+15 | -17..+10 |
| Gundam EX | up to +7 | -73..+22 | -20..+14 |
| Mahjong Yonshimai | up to +10 | -67..+31 | -12..+7 |
| My Angel, My Angel 2 | up to +14 | -61..+43 | -12..+7 (My Angel 2: -11..+8) |
| Puzzle De Bowling | up to +14 | -54..+44 | -13..+7 |
| Penguin Brothers, A-Blast | up to +9 | -67..+23 | -12..+23 |

The pictures sit right of the line's middle (the right margin is the smaller), so a larger H-Size fits with the picture moved left.

## Status

**Verification.** MAME 0.289 is the reference. In simulation (Verilator, the games' real programs, the real SDRAM path): every ROM region of the 23 sets byte-identical
to what MAME loads; the video chip on frozen MAME states, 234 of 240 frames of the first ten sets pixel-identical (the other six are Guardians' raster-interrupt frames,
which MAME draws in pieces); the whole machine from reset, the boot and attract pictures of every set equal to MAME's, a few frames apart; Guardians' scripted play pixel
for pixel through its gameplay; Deer Hunting's scripted hunt (2400 frames) pixel for pixel but for the randomly drawn wind, and its battery RAM at the end MAME's byte for
byte; Wing Shooting played by two players, both hunters' choices on the same frames as in MAME; the X1-010 sample by sample against MAME's algorithm (every sample within
1 LSB); the fast and streamed loads byte-exact; CRT Adjust and the light guns' aim in unit benches. `docs/status.md` has the measured results, the bugs found on the way
and the open points.

**On a real MiSTer** (the owner's MiSTer Multisystem 2, with a RetroTINK 4K in DV1 mode and with a 15 kHz CRT):

* **Release 20261020** (the first): every game loads and plays, picture and sound; the named buttons, CRT Adjust, Turbo CPU / CPU speed, DV1 and fast loading work. The
  first tests found, and the builds since fix: a black screen (the fast load's header), a shredded picture on DV1 (now one core file per board dot clock), Gundam EX's
  black screen when its demo starts (the decoding of its second program ROM), a dark, unsteady picture on the CRT (the long sync pulses the games program: Sync widths)
  and the RT4K's "MiSTer Gen." class for Guardians and Penguin Brothers (now 262 lines: Video and sound).
* **Build 20261021** (the light-gun games): every game, new and old, plays; the guns aimed with the gamepad's d-pad and analog stick, the crosshair shown. Not tried on
  the hardware yet: the mouse, a real gun (Sinden / GUN4IR) and high scores kept over a reload. The simulation's two-player play found, before this build, that player 2's
  gun was not decoded (Wing Shooting, Trophy Hunting).

**Known differences from MAME**

* Random choices can come out differently: Deer Hunting's wind, Wing Shooting's attract birds and hunting spot. MAME 0.289's X1-010 returns a channel's "playing" flag
  without bringing the sound up to date, so a flag clears there only at its next sound update; the core clears it when the sample ends, and the games poll the flags.
* The frame rates are the boards' (below), not MAME's 60 Hz, and program reads that miss the CPU's cache wait for the DDR3 (MAME has no wait states): the attract modes
  run a few frames apart from MAME's.
* The raster interrupt and the palette: the core draws each line just ahead of the beam and looks the palette up as the dots go out; a replay of MAME's writes shows
  that this gives MAME's pictures in Guardians' raster scenes; a palette fade written during a frame can show one step apart for a frame.

## Video and sound

TMP68301 and X1-010 at 50 MHz / 3 = 16.667 MHz (Gundam EX, the P0-113A Guardians and the bootleg: 32.53047 MHz / 2), as MAME. The picture uses the CRTC values the games
program, with each board's dot clock: the 384-wide games 8.13 MHz, ~60.0 Hz (261-262 lines). Guardians and Penguin Brothers / A-Blast get 262 lines instead of their
CRTC's 259 and 256, with a line two or four dots shorter so that the frame rate stays near the boards' (Guardians) or MAME's (Penguin Brothers): Guardians 6.25 MHz,
409 x 262, 58.3 Hz (CRTC 411 x 259 = 58.7 Hz; measured on the boards: 58.27-58.5 Hz); Penguin Brothers 7 MHz, 445 x 262, 60.0 Hz (CRTC 449 x 256 = 60.9 Hz). The
RetroTINK 4K sorts a MiSTer direct-video signal into a class by its lines per frame: with 259 or 256 lines it took these games as "MiSTer Gen.", in which it squashes the
picture while the MiSTer OSD is open, and with 262 as "MiSTer 240p", like the other games. The picture and the syncs keep their positions; the added lines and the
removed dots are blanking. The light-gun games (Sammy's board, MAME's `samshoot`) run as their CRTC says: 7 MHz, 446 x 262, 59.9 Hz; their second interrupt is MAME's
60 Hz periodic one, counted from the CPU clock.

The video chip (`rtl/s2_video.sv`, `rtl/s2_render.sv`) is written from MAME's `x1_020_dx_101.cpp`: sprites and tile sprites drawn a line ahead of the beam from the
SDRAM. Sound: the X1-010 (ppriest's `x1_010.sv`, MAME's sound chip transcribed: Credits) with the sample banks of each board.

## Build

Quartus Prime Lite **17.0.2** (the version MiSTer's framework needs). The project has three revisions, one per core file:

    quartus_sh --flow compile Seta2 -c Seta2        -> output_files/Seta2.rbf      seta2
    quartus_sh --flow compile Seta2 -c Seta2Grd     -> output_files/Seta2Grd.rbf   seta2grd
    quartus_sh --flow compile Seta2 -c Seta2Pen     -> output_files/Seta2Pen.rbf   seta2pen

`py -3.8 tools/release.py [--builds <dir>]` copies them to `releases/` as `seta2_<date>.rbf` / `seta2grd_<date>.rbf` / `seta2pen_<date>.rbf` with their fitter, timing
and RAM-depth reports (it fails on a negative slack); `py -3.8 tools/package.py` writes the release zip (`dist/Seta2_MiSTer_<date>.zip`, the SD card's structure, no
ROMs) from `releases/` and `mra/`; `py -3.8 tools/make_mra.py` writes the MRAs.

## Simulation and tools

Verilator benches in `sim/` (run in WSL; they build in `$HOME/build_seta2`):

    sim/video/run.sh <statedir> <frame>...                     the video chip on frozen MAME states, vs MAME's pixels
    sim/sys/run.sh <image> <frames> <out> +every=10 [+wav]     the whole machine from reset (sim/sys/runb.sh <set> ...: on its core file's clocks)
    sim/snd/run.sh <x1.log> <x1snd.bin> <seconds> <out.wav>    the X1-010 with MAME's register writes
    sim/crt/run.sh [15 13 11]                                  CRT Adjust on each core file's rasters
    sim/guns/run.sh                                            the light guns' aim, buttons and crosshair

The machine bench takes scripted inputs (`+inputs=`: `tools/play_inputs.py`, `tools/gun_inputs.py` for the light guns), loads and dumps the battery RAM (`+nvload=`,
`+nvdump=`) and runs the fast and streamed loads (`+fastload`, `+stream`). `tools/capture.py` runs MAME headless with `tools/lua/dump_state.lua` (states, pixels, the
same scripted inputs); `tools/sys_match.py` / `tools/sys_lag.py` compare the bench's pictures with MAME's; `tools/seta2_ref.py` is the Python reference renderer,
`tools/seta2_image.py` builds a set's ROM image. MAME's captures, the images and the benches' pictures go to a scratch folder `work/` next to the repository (never
committed); `tools/paths.py` says where MAME, the romsets and MAME's source are.

## Repository layout

| | |
|---|---|
| `Seta2.sv`, `Seta2*.qsf`, `Seta2.qpf`, `Seta2.sdc`, `files.qip` | the MiSTer top level (OSD, inputs, DIP switches, the light guns, the battery RAM file, video, audio) and the Quartus project with its three revisions |
| `rtl/` | the machine: TMP68301 board and memory maps, video chip (renderer, SDRAM fetch), ROM loader, SDRAM controller and program cache, EEPROM, clock enables (Turbo), CRT Adjust glue, light guns and their ports, battery RAM file |
| `modules/` | other people's cores, with their licences (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework |
| `mra/` | the MRAs: one a title in the folder, the other versions in `_alternatives/_<Title>/` |
| `releases/` | the RBFs of the releases with their fitter, timing and RAM-depth reports |
| `docs/` | `status.md` (results, measurements and process notes), the title screens |
| `tools/`, `sim/` | MRA writer, ROM-image builder, reference renderer, MAME scripts, benches |

## Credits

* **MAME** (the seta2 driver and the X1-020 / DX-101 video chip by Luca Elia and David Haywood, the TMP68301 by Olivier Galibert, the X1-010 by Luca Elia with the
  rewrite by Manbow-J, the serial EEPROM by Aaron Giles; BSD-3-Clause): the hardware knowledge and the oracle for every comparison.
* **ppriest / Paul Priest**: [Arcade-Seta_MiSTer](https://github.com/ppriest/Arcade-Seta_MiSTer)'s `x1_010.sv`, MAME's X1-010 transcribed (GPL-3.0; `modules/x1_010`),
  and his light guns, `gx_guns.sv` of his Konami GX core and the Zombie Raid guns of Arcade-Seta_MiSTer, which `rtl/s2_guns.sv`'s aiming follows (GPL-3.0-or-later).
* **Jorge Cwik** ([fx68k](https://github.com/ijor/fx68k), GPL-3.0), **rmonic79 / Umberto Parisi**, with Andrea Bogazzi
  ([MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust), GPL-3.0-or-later).
* **kandowontu**: [Arcade-Guardians_MiSTer](https://github.com/MiSTer-devel/Arcade-Guardians_MiSTer) and
  [Arcade-GundamEX_MiSTer](https://github.com/kandowontu2/Arcade-GundamEX_MiSTer), read as references (board maps, CRTC values, Guardians' timer and raster
  interrupt), and the model of the Turbo CPU / CPU speed options.
* **plasticbugs** (`tools/mra_build.py`, from analogue-pocket-gaiapolis, GPL-3.0): the MRA assembly and md5 check.
* **The MiSTer framework** (Sorgelig and contributors); the platform layer, fast loading and Scale follow the owner's other cores (Oh My God!, Monster Maulers, Heavy
  Unit), the CRT Adjust glue the Metro core's.

## Licence

GPL-3.0-or-later (`LICENSE`); vendored modules keep their own licences (`modules/VENDOR.md`).

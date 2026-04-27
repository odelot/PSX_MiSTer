# PSX_MiSTer — RetroAchievements Fork

This is a fork of the official [PSX core for MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) with modifications to support **RetroAchievements** on MiSTer FPGA.

> **Status:** Experimental / Proof of Concept — works together with the [modified Main_MiSTer binary](https://github.com/odelot/Main_MiSTer).

## What's Different from the Original

The upstream PSX core is an FPGA PlayStation implementation. This fork adds two new modules and minor wiring changes so the ARM side (Main_MiSTer) can read emulated PSX RAM for achievement evaluation. **No emulation logic was changed** — the core plays games identically to the original.

### Added Files

| File | Purpose |
|------|--------|
| `rtl/ra_ram_mirror_psx.sv` | Selective-address mirror with RTQuery mailbox (FPGA v2): serves batched cache updates and realtime single-read queries |
| `rtl/ddram_arb_psx.sv` | DDRAM arbiter that gives the PSX core priority while allowing the RA module to use idle cycles |

### Modified Files

| File | Change |
|------|--------|
| `PSX.sv` | Instantiates both new modules, wires SDRAM CH4 for RA reads, adds DDRAM read/write channels |
| `files.qip` | Adds both new `.sv` files to the Quartus project |

### How the RAM Mirror Works (Simplified Algorithm)

The PSX has 2 MB of main RAM — too large to copy wholesale every frame. The current implementation uses **Smart Option C** in Main_MiSTer plus FPGA RTQuery support:

1. A one-time bootstrap collect seeds the address cache (`0x40000` list / `0x48000` values).
2. During gameplay, cached addresses are read normally from FPGA responses.
3. If an address is missing (common in pointer-heavy `AddAddress` / `AddSource` conditions), Main_MiSTer performs an immediate **RTQuery** read via mailbox at `0x50000`.
4. Newly discovered addresses are appended dynamically and flushed to FPGA cache; no periodic pointer re-collect loop is needed.

The `ddram_arb_psx.sv` arbiter ensures the PSX core always has priority on the DDRAM bus — the RA module only accesses DDRAM during idle cycles, so there is no impact on emulation timing.

**Memory region exposed:**

| Region | PSX Address | Size | Description |
|--------|------------|------|-------------|
| Main RAM | $000000–$1FFFFF | 2 MB | All game variables, stack, heap — byte-addressed linearly |

### DDRAM Layout

```
0x00000   Header:   magic ("RACH") + flags + frame counter
0x40000   AddrReq:  ARM → FPGA address request list (count + request_id + addresses)
0x48000   ValResp:  FPGA → ARM value response cache (response_id + response_frame + values)
0x50000   RTQuery Ctrl: request_seq/response_seq/num_queries
0x50008   RTQuery Req:  up to 16 realtime queries (address + size)
0x50088   RTQuery Resp: realtime values returned by FPGA
```

All data flows through shared DDRAM at ARM physical address **0x3D000000**.

### Architecture Diagram

```
┌───────────────────────────────────────┐
│          PSX FPGA Core                │
│                                       │
│  Main RAM (2MB) in SDRAM              │
│  accessed via CH4                     │
└─────────────┬─────────────────────────┘
              │  VBlank
              ▼
┌───────────────────────────────────────┐
│     ra_ram_mirror_psx.sv              │
│  Reads requested addrs from SDRAM CH4 │
│  Writes header + values to DDRAM      │
│                                       │
│     ddram_arb_psx.sv                  │
│  Arbitrates DDRAM: PSX core first,    │
│  RA module on idle cycles             │
└─────────────┬─────────────────────────┘
              │  DDRAM @ 0x3D000000
              ▼
┌───────────────────────────────────────┐
│     Main_MiSTer (ARM binary)          │
│  mmap /dev/mem → reads mirror         │
│  Writes address list → reads values   │
│  rcheevos hashes disc + evaluates     │
└───────────────────────────────────────┘
```

### CD / Disc Hashing

Unlike cartridge-based systems, PSX games are disc images. The Main_MiSTer binary uses the `rc_hash_generate_from_file()` function from the rcheevos library, which handles `.cue+.bin`, `.chd`, and `.iso` formats transparently — no manual header-skipping needed.

## How to Try It

1. Download the latest PSX core binary (`PSX_*.rbf`) from the [Releases](https://github.com/odelot/PSX_MiSTer/releases) page.
2. Copy the `.rbf` file to `/media/fat/_Console/` on your MiSTer SD card (replacing or alongside the stock PSX core).
3. You will also need the **modified Main_MiSTer binary** from [odelot/Main_MiSTer](https://github.com/odelot/Main_MiSTer) — follow the setup instructions there to configure your RetroAchievements credentials.
4. Reboot your MiSTer, load the PSX core, and open a game that has achievements on [retroachievements.org](https://retroachievements.org/).

## Building from Source

Open the project in Quartus Prime (use the same version as the upstream MiSTer PSX core) and compile. Both `ra_ram_mirror_psx.sv` and `ddram_arb_psx.sv` are already included in `files.qip`.

## Links

- Original PSX core: [MiSTer-devel/PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer)
- Modified Main binary (required): [odelot/Main_MiSTer](https://github.com/odelot/Main_MiSTer)
- RetroAchievements: [retroachievements.org](https://retroachievements.org/)

---

# Original PSX Core Documentation

*Everything below is from the upstream [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) README and applies unchanged to this fork.*

## [Playstation](https://en.wikipedia.org/wiki/PlayStation_(console)) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

## Hardware Requirements
SDRAM of any size is required.

## Features
* Savestates
* Option for core pause when OSD is open
* Optional manual Memory Card file loading (.MCD)
* CUE+BIN and CHD format support
* Multiple Disc Game support with automatic Lid open/close toggle
* Fast Boot (Skips BIOS)
* Dithering On/Off Toggle
* Bob or Weave Deinterlacing
* Texture Filtering
* 24 Bit rendering
* Widescreen modes
* Screen rotation by 180°
* 8 Mbyte mode(from dev units, mostly for homebrew) 
* Inputs: DualShock, Digital, Analog, Mouse, NeGcon, Wheel, Justifier and Guncon support.
* Native Input support through SNAC
* Old GPU (CXD8514Q)

## Bios
Rename your playstation bios file (e.g. `scph-1001.bin`/`ps-22a.bin` ) and place it in the `./games/PSX/` folder.

```
boot.rom  => US BIOS
boot1.rom => JP BIOS
boot2.rom => EU BIOS
```

You can also place a cd_bios.rom in the same directory as the CD or 1 directory above, to have it uses together with that CD. This can be used for games that depend on a special BIOS beyond usual US,EU,JP.

If you get a black screen with "ED" overlay in upper left corner, either your BIOS files are corrupt or missing or you have no SDRAM module installed.

## Region

Region settings (e.g. Clock, BIOS, CD check) are selected automatically when loading a CD. You can force a different Region in OSD.

## Memory Card

Games that are in their own folder will create it's own memory card in media/fat/saves/psx as <folder name>.sav 

One card can be mounted for each controller slot. Cards are in raw .mcd format. An empty formatted .mcd file is available for [download here](https://github.com/MiSTer-devel/PSX_MiSTer/raw/main/memcard/empty.mcd).

You need to save them either manually in the OSD or turn on autosave. Saving or loading a card will pause the core for a short time.

## Multiple Disc Games

To swap discs while the game is running, all disc files for the game must be placed in the same folder. When a disc change is required, the core will automatically simulate opening and closing the disc lid. Example folder structure of a multi-disc game:

```
/media/fat/games/PSX/Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 1).chd
/media/fat/games/PSX/Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 2).chd
/media/fat/games/PSX/Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 3).chd
```

## Video output

Core can output through HDMI and Analog out.

HDMI also offers a debugging framebuffer mode with support of full VRAM as 1024x512 pixel image(debug only)

Analog out from Direct Video is full 24Bit Color, but from Analog Board will only deliver 18 Bits of color.
You can activate the 24 Bit dithering option to remove color banding in FMVs without decreasing the image quality in 16 bit color ingame.
Do not use with HDMI or you get artifacts!

Fixed Hblank as well as Fixed Vblank can help delivering correct aspect rations and keeping the screen in sync with e.g. shaking animations.
Both also offer crop options for games that depend on CRT viewports to hide artifacts at the edge of the image.

Sync 480i for HDMI will make 480i content run with 240p timings, making it easier for HDMI devices to keep the sync when switching between both modes in games. 
Do not use with VGA/Analog out or you get artifacts!

## Libcrypt

Some games are secured with Libcrypt and will not work if it's not circumvented.

You can provide a .sbi file to do that.
If there is a .sbi file next to a .cue with the same name, it is loaded automatically when mounting the CD image.

## Unsafe options

The core offers various options to improve gameplay for some games, but those options cannot be considered stable through all games.
If you use one or more of these options, the core will warn you every time you start a game.

- 480i to 480p hack: 
Allows to render some games with full 480p resolution, removing interlacing artifacts. Only works for some full 3D 480i titles.

- Turbo: 
Increases CPU, DMA, Memory and GTE performance by ~10%(Low), ~20%(Medium) or 50%(High). Cheats cannot be used while Turbo is on and are disabled automatically.

- Pause when CD slow: 
CD data must be returned in a fixed time frame, otherwise the core will pause until the data has arrived. Disabling this will remove these pauses, but also risk that the game hangs up due to CD data being late.

- PAL 60Hz Hack:
Runs PAL games with 60Hz. PAL Games will often run faster with this hack on. Screen height is limited to 256 lines in this mode, so some games might be cropped.

- CD Fast Seek:
CD will seek the next sector in the minimal possible time. Decreases loading time of games, but some games depend on the long loading times and will crash.

- CD Speed:
Allows to run the CD drive with fixed higher speed to decrease loading times, but some games depend on the long loading times and will crash.
CD will automatically speed down to original speed for FMVs or CD audio playback and back to increased speed in loading areas.
The higher speed rates are more unstable and require proper storage to be usable with bin/cue files reaching higher performance than chd.

- Limit Max CD Speed:
Will hold back any new CD data until the game has processed the last data. 
Mostly useful to prevent CD data overrun when using higher speed modes, leading to overall faster loading times due to less read retries.

- RAM:
8 Mbyte option from development consoles. Only use for homebrew that requires it, otherwise there is a high chance of crashing games.

## Error messages

If there is a recognized problem, an overlay is displayed, showing which error has occured.
You can hide these messages with an OSD option, by default they are on.

List of Errors:
- E2     - CPU exception(only relevant if game shows issues)
- E3..E6 - GPU hangs (e.g. corrupt display list)
- E7     - CPU2VRAM with mask-AND enabled
- E8     - DMA chopping enabled
- E9     - GPU FIFO overflow
- EA     - SPU timeout
- EB     - DMA and CPU interlock error 
- EC     - DMA FIFO overflow
- ED     - CPU Data/Bus request timeout -> will also appear if the BIOS is not found or corrupt or no SDRAM module is installed
- EF     - BusWidth for SPU was set to 8 Bit (but should be 16 bit)

## Debug Options

The debug menu is intended for use by developers only. They don't really serve any purpose for regular users so it's best to leave them at their default setting as a lot of undesirable behavior could occur.

## Pad Options
The following pad types are emulated by the core and can be independently assigned to each port:
- DualShock:
  Switch Digital/Analog mode with mouse/touchpad click or L3+R3+Up/Down or mapable button 
- Digital  
  (ID 0x41) Ten button digital pad.
- Analog  
  (ID 0x73) Twinstick pad.  
- Mouse  
  (ID 0x12) Two button mouse.
- Off  
  Pad unplugged from port.
- GunCon  
  (ID 0x62) GunCon compatible lightgun.
- Justifier  
- NeGcon  
  (ID 0x23) NeGcon compatible racing pad.  
  Primarily developed for dual analog stick usage with the following mapping (genuine NeGcons  
   may work if usb adapters map steering to Left Analog and I/II to Right Analog):
   - Steering -> Left Analog (you can also use a paddle controller for this axis)
   - Circle -> Circle
   - Triangle -> Triangle
   - I -> Right Analog Up, Cross (100% pressed), R2 (100% pressed)
   - II -> Right Analog Down, Rectangle (100% pressed), L2 (100% pressed)
   - L -> L1 (100% pressed)
   - R -> R1
   
SNAC can be selected for each port and will support gamepads and memory cards on the corresponding slot.
When SNAC is enabled for a slot, the emulated gamepad/memory for this slot is disconnected.

## Controller mapping reference
NeGcon based controllers

| DualShock (for reference) | NeGcon | Volume | Pachinko |
|:-------------------------:|:------:|:------:|:--------:|
| D-PAD                     | D-PAD  |        |          |
| RX Axis                   | Twist  | Paddle | Handle   |
| RY Axis                   | I      |        |          |
| LX Axis                   | L1     |        |          |
| LY Axis                   | II     |        |          |
| O                         | A      | B      |          |
| △                         | B      |        |          |
| R1                        | R1     |        |          |
| Start                     | Start  | A      | Button   |

Lightgun
  
| DualShock (for reference) |   Guncon  | Justifier |
|:-------------------------:|:---------:|:---------:|
| O                         | Trigger   | Trigger   |
| Start                     | A (Left)  | Start     |
| X                         | B (Right) | Special   |
  
## Status

Many games working

--

CPU    : 90%
- exception for read in invalid instruction and data area missing

GPU    : 90%
- mask bits not implemented for cpu2vram -> nothing yet found that uses it
- vram2vram read/modify/write race condition when copying to same line

IRQ    : 90%
- irq_SIO missing because unused        

PAD    : 90%
- full configurable multitap missing

Memctrl: register stubs only

SIO    : register stubs only

Timer  : 90%
- accuracy for dotclock and gates timer not tested

GTE    : 90%
- CPU <-> GTE Transfer pipeline delay not fully correct

MDEC   : 90%
- timing slightly too fast (4996/5376)
 
CD     : 90%
- accurate CD access model for correct seek times should be added
- drive and controller logic should be seperated

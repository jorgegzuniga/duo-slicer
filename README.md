# Duo Slicer

An iPhone slicer for the Bambu Lab A1. Open a Bambu 3MF, look through its plates in 3D, re-orient parts, change settings, slice on the phone, and send the plate straight to the printer over your home Wi-Fi. No computer involved.

## What it does

- **Opens Bambu Studio 3MF projects** with all their plates, objects, colours and per-object settings (from Files, MakerWorld, Safari, Mail, or the share sheet).
- **3D plate view**: tap a part to select it, rotate 90° or 15° on any axis, tap a face to put it on the bed, or auto-flatten. Parts that hang off the 256 × 256 mm bed are flagged.
- **Settings**: Bambu's own A1 quality presets (0.08–0.28 mm), build plate, walls, top/bottom layers, infill density and pattern, brim, skirt; filament material and colour per slot.
- **Slices on the phone** with its own engine (C++, Clipper2 for polygon work) and the A1's official start, filament-change (AMS lite) and end G-code from Bambu's profiles. Multi-colour plates get proper AMS lite flushing.
- **Layer preview**, print time, grams per colour, colour-change count.
- **Sends to the A1 over LAN**: matches each colour to the closest AMS lite spool, uploads to the printer's microSD over FTPS and starts the print over MQTT. Shows live progress with pause, resume and stop.

## Limits (v1)

- No supports yet (flat and layered prints don't need them). Supports in a project are left out with a warning.
- Infill patterns: grid and lines. Other patterns print as grid.
- Walls use the classic (fixed-width) generator, so features thinner than one line width (about 0.4 mm) are dropped, as in Bambu Studio's classic mode.
- No prime tower; purging happens in the A1's chute during each colour change, as Bambu Studio does.
- Painted multi-colour regions inside a single part use that part's dominant colour.

## One-time printer setup

1. Update the A1 to firmware 01.05 or newer.
2. Insert a microSD card. Jobs sent over the network are stored on it.
3. On the printer: Settings → WLAN → turn on **LAN-only Mode**, restart the printer, then turn on **Developer Mode** in the same menu.
4. In the app, open **Printer** and enter the IP (Settings → WLAN), serial number (Settings → Device) and access code (shown under LAN-only Mode).

While LAN-only Mode is on, Bambu Handy and cloud printing don't work for this printer.

## Building and TestFlight

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; CI builds on GitHub's macOS runners.

- `.github/workflows/build.yml` runs on every push: the engine self-test (slices a generated two-colour tile and checks the G-code) and an unsigned simulator build of the app.
- `.github/workflows/testflight.yml` archives, signs and uploads to TestFlight on pushes to `main` once these repository secrets exist:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Your 10-character Team ID (developer.apple.com → Membership) |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | The issuer ID shown above the keys list |
| `ASC_KEY_P8` | The full text of the downloaded `AuthKey_XXXX.p8` file |

Before the first upload, create the app record in App Store Connect (My Apps → + → New App) with bundle ID `com.jorgegzuniga.duoslicer`. Builds then appear in TestFlight a few minutes after the workflow finishes.

## Engine development

```sh
./build_cli.sh                      # builds ./a1cli on macOS or Linux
./a1cli Resources/a1-profiles.json project.3mf <plateIndex> options.json out.gcode.3mf
./tools/engine_selftest.sh          # what CI runs
```

`Resources/a1-profiles.json` holds Bambu Studio's A1 machine, process and filament presets, resolved from the open-source [BambuStudio](https://github.com/bambulab/BambuStudio) profiles (AGPL-3.0). Clipper2 is under the Boost Software License; nlohmann/json under MIT.

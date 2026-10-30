# Duo Slicer

An iPhone slicer for Bambu Lab and Snapmaker printers, made for the iPhone Duo. Open a 3MF, look through its plates in 3D, re-orient parts, change settings, slice on the phone, and send the plate to your printer over your home Wi-Fi. No computer involved. Claude can drive it too.

## Printers

| Printer | How it prints |
| --- | --- |
| Bambu Lab A1, A1 mini, A2L, P1P, P1S, P2S, X1, X1 Carbon, X1E, H2S | AMS colour changes with purging in the chute; `.gcode.3mf` uploaded over FTPS and started over MQTT (LAN-only mode) |
| Snapmaker U1 | One head per colour (up to four), standby and pre-heat temperatures between switches; G-code uploaded and started through Moonraker |

The dual-nozzle Bambu printers (H2D, H2D Pro, H2C, X2D) aren't supported yet. Save as many printers as you have: Duo Slicer stays connected to all of them while it's open. The project screen slices for the selected one, and plates are re-placed on its bed (with **Center on bed** for plates made for a bigger printer).

## What it does

- **Opens Bambu Studio and OrcaSlicer 3MF projects** with their plates, objects, colours and per-object settings (Files, MakerWorld, Safari, Mail, the share sheet, or drag and drop).
- **3D plate view** on the target printer's bed: tap a part to rotate it 90° or 15° on any axis, tap a face to put it down, auto-flatten, or reset. Parts that don't fit the bed, are too tall, or sit in the X1/P1 cutter corner are flagged.
- **Move and arrange parts**: drag a selected part across the bed, type its X/Y position or nudge it 1, 5 or 10 mm, or **Arrange** the plate (packed front-left with a 6 mm gap, clear of the cutter corner, optionally turning parts to fit). **Move to plate** sends a part to another plate or a new one; empty plates can be removed, and **Undo** (⌘Z) steps back through all of it. The edits are saved in the 3MF you share.
- **Settings**: each printer's own quality presets, build plate, walls, top/bottom layers, infill, brim, skirt; filament preset and colour per slot. On the U1, which head prints each colour, matched to the filament loaded in each head.
- **Slices on the phone** with its own engine (C++, Clipper2) and each printer's official start, filament-change and end G-code from the Bambu Studio and OrcaSlicer profiles.
- **Layer preview**, print time, grams per colour, colour changes.
- **Finds printers on your Wi-Fi**: tap yours; a Bambu printer needs only its access code, a U1 nothing.
- **Prints over LAN** with live progress, pause, resume and stop.
- **All your printers at once**: the Printers screen shows each one's state and progress; each printer's page has its camera, controls, what's loaded (AMS slots or U1 heads) and its part of the queue.
- **Printer cameras**: A1 and P1 (the printer's JPEG stream), X1, H2S and P2S (the RTSPS live view, decoded on the phone; turn on **LAN Mode Liveview** on the printer) and the Snapmaker U1 (its camera snapshots through Moonraker). The camera shows on the Print panel while a print runs, and a tap away before one, to check the bed.
- **Print queue**: line up plates from different projects, all plates of one, or copies (**Add to print queue** on the Print panel or the ⋯ menu), for one printer or whichever printer of that model is free first. The queue keeps a copy of each project as it was, slices a plate when its printer is free, and sends it once you say the bed is clear; after each print it waits for you to say the bed is clear again (nothing removes finished prints for you), and when another print is waiting, a notification reminds you around the time the current one should be done. Reorder, retry or remove jobs any time.

## iPhone Duo

Built with the iOS 27.1 SDK so the app fills the inner screen. The project screen follows the device:

- **Unfolded, held wide**: 3D view on the left half, panels on the right half; the split sits exactly on the crease (from UIKit's reserved regions, or the middle of the inner screen if UIKit doesn't report one), so nothing you tap lands on the fold. Each half has its own header (Close and the project name on the left, the panel tabs and ⋯ menu on the right) instead of a title over the crease. The home screen splits the same way: projects on one side, printer and Claude on the other.
- **Unfolded, held tall or half-folded**: 3D view on the top half, panels below.
- **Folded** (outer screen) and in Split View: one column with the panel under the 3D view.
- iPad and other large windows get the side-by-side layout, with a plates sidebar on very wide windows. ⌘O, ⌘R (slice), ⌘P (print) and ⌘1–⌘4 work with a keyboard.

## Use with Claude

Duo Slicer can be a custom connector in Claude. Claude can list and open projects, read plates and settings, change settings, rotate, move and arrange parts, move parts between plates, slice, look at layer previews, check every printer, look through a printer's camera, start prints and run the print queue. Starting or stopping a print, and starting the queue (which means the beds are clear), always waits for you to approve it on the phone, and the app has to be open.

How it connects: the app keeps a WebSocket to a small relay (`relay/`, a Cloudflare Worker with a Durable Object) and Claude talks MCP to the same relay. Each phone has its own secret, which is part of the connector URL.

1. Make a free Cloudflare account. In **My Profile → API Tokens**, create a token from the **Edit Cloudflare Workers** template.
2. Add two repository secrets: `CLOUDFLARE_API_TOKEN` (that token) and `CLOUDFLARE_ACCOUNT_ID` (shown on the Workers overview page).
3. The **Claude relay** workflow deploys the relay on the next push to `main` (or run it by hand). TestFlight builds pick up its address automatically.
4. In the app: **Use with Claude** → turn it on → **Copy connector URL**.
5. In Claude: **Customize → Connectors → + Add → Add custom connector**, paste the URL and choose **No sign in**. Turn the connector on in a chat from the **+** menu.

Anyone with the connector URL can use these tools while the app is open, so keep it private; **Make a new connector URL** in the app retires the old one.

## Limits

- No supports yet (flat and layered prints don't need them). Supports in a project are left out with a warning.
- Infill patterns: grid and lines. Other patterns print as grid.
- Walls use the classic (fixed-width) generator, so features thinner than one line width (about 0.4 mm) are dropped.
- No prime tower: Bambu printers purge in the chute during each colour change; the U1 primes each head with its own pre-extrude routine.
- Painted multi-colour regions inside a single part use that part's dominant colour.
- Prints one layer at a time across all parts (no by-object sequence).

## Adding a printer

Put the printer on the same Wi-Fi as the iPhone and tap **Add printer**: Duo Slicer searches the network and lists the Bambu Lab printers and Snapmaker U1s it finds (Bambu printers by their serial number, which also tells the model; the U1 by its Moonraker service). If a Bambu printer later gets a new address from the router, the next search updates it. You can still type an IP address instead.

**Bambu Lab**: tap the printer and type the access code from its screen (Settings, network/WLAN page). The app signs in once to check the code and to confirm the model. Before that, on the printer: update the firmware, insert a microSD card (network jobs are stored on it), turn on **LAN-only Mode** and restart, then turn on **Developer Mode**. While LAN-only Mode is on, Bambu Handy and cloud printing don't work for that printer.

**Snapmaker U1**: tap it; nothing else to enter (Moonraker on port 7125, no API key unless you set one). Load filament in each head so colours can be matched.

The search tries every address on the Wi-Fi network (your /24 on bigger networks) instead of listening for the printers' broadcasts, which iOS only allows for apps with Apple's multicast entitlement. iOS asks once for Local Network access.

## Building and TestFlight

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. CI uses GitHub's `xcode-27` runner (Xcode 27.1).

- `build.yml` (every push): engine self-test for all eleven printers, relay smoke test, simulator build, demo screenshots on the iPhone Duo's outer screen, an end-to-end run where MCP calls go through a local relay to the app in the simulator, the unfolded inner screen (Device Hub's posture bar is clicked to open the simulated Duo, since `simctl` can't unfold it), and runs against stand-in printers on the runner (`ci/fake_printers.py`: a P1S with MQTT, FTPS and its JPEG camera, an X1 Carbon with its RTSPS H.264 camera, and a Snapmaker U1's Moonraker) for Add printer, the Printers screen, each camera and the print queue sending plates to them — all pushed to the `screenshots` branch. A second job draws the unfolded layouts at the inner screen's size on a 13-inch iPad simulator, held wide and tall (`screenshots-inner` branch).
- `testflight.yml` (pushes to `main`): archives, signs and uploads to TestFlight with the `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` secrets.
- `relay.yml` (pushes to `main` that touch `relay/`): deploys the Claude relay with the Cloudflare secrets.

## Engine development

```sh
./build_cli.sh                                   # builds ./a1cli on macOS or Linux
./a1cli Resources/profiles/bambu-x1c.json project.3mf <plateIndex> options.json out.gcode.3mf
./tools/engine_selftest.sh                       # what CI runs
python3 tools/validate_printers.py ./a1cli project.3mf:0,1   # every printer, with bed and template checks
```

`Resources/profiles/` holds one resolved profile bundle per printer, built by `tools/build_profiles.py` from the open-source [BambuStudio](https://github.com/bambulab/BambuStudio) and [OrcaSlicer](https://github.com/SoftFever/OrcaSlicer) profiles (AGPL-3.0). Clipper2 is under the Boost Software License; nlohmann/json under MIT.

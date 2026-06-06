# Dusk

A tiny macOS command-line tool that **turns off your MacBook's built-in display when an external display is connected**, and restores it when the external is unplugged.

It automates what people otherwise do by hand: keep the lid open, mirror the laptop to the external, and drag the laptop brightness to zero — so you can use the external as your only screen while the lid stays open (for the camera, airflow, or just preference).

> Single purpose, zero dependencies, one small binary. Install it, let it run in the background, forget about it.

```
external display connected   →  built-in display goes dark
external display disconnected →  built-in display comes back
only the built-in display     →  nothing happens (never turns off your only screen)
```

## Install

### Quick install (recommended)

One line — no Homebrew, no Xcode, no manual downloads. It grabs the latest universal binary (Apple Silicon + Intel), verifies its checksum, and installs it to `/usr/local/bin`:

```bash
curl -fsSL https://raw.githubusercontent.com/kqw8/Dusk/main/scripts/install.sh | bash
```

Then turn it on:

```bash
dusk install   # run it in the background (start-at-login off by default)
```

> The binary isn't notarized by Apple, but installing over `curl` avoids the Gatekeeper warning (only browser downloads get quarantined). The full source is in this repo if you'd rather build it yourself.

### Build from source

Requires the Swift toolchain (Xcode **or** just the Command Line Tools — `xcode-select --install`).

```bash
git clone https://github.com/kqw8/Dusk.git
cd Dusk
swift build -c release
.build/release/dusk install
```

## Usage

```
dusk            Run in the foreground (for debugging; Ctrl-C to quit)
dusk install    Install + start the background agent (login-autostart OFF by default)
dusk uninstall  Stop, restore the built-in display, and clean up
dusk start      Start the background agent
dusk stop       Stop the background agent and restore the built-in display
dusk login on   Enable start-at-login
dusk login off  Disable start-at-login (default)
dusk status     Show displays + tool state
```

Background residency is **on** by default after `install`. Start-at-login is **off** by default — turn it on with `login on` when you want it to come back after a reboot.

## How it works

When an external display is connected, the tool:

1. **Mirrors** the built-in display to the external (via the public `CGConfigureDisplayMirrorOfDisplay` API), so the built-in is no longer a separate desktop the cursor or windows can wander onto.
2. **Disables auto-brightness** on the built-in panel, so the next step actually sticks.
3. **Sets the built-in brightness to 0**, turning the panel dark.

On disconnect it reverses all of that.

**Manual override:** while an external is connected, if you switch the built-in back to *extended* mode or raise its brightness yourself, Dusk takes the hint — it hands the built-in back and stays out of your way until you reconnect the external. It never traps you with a screen it won't give back.

macOS has **no public API to truly "turn off" a single display**, so dimming the backlight to zero is the closest thing — this is the same approach used by tools like BetterDisplay, MonitorControl, and Lunar. Brightness and auto-brightness are controlled through Apple's private `DisplayServices` framework, which is loaded at runtime (`dlopen`); if a macOS update ever removes those symbols, the tool degrades gracefully and tells you instead of misbehaving silently.

It is **event-driven** (no polling): it reacts to display reconfiguration and wake events. It runs as a `launchd` user agent and keeps no log while healthy — it only speaks up (a notification + `status`) when something fails. Those failures are also captured in `~/Library/Logs/dusk.out.log` and `dusk.err.log`.

## Permissions

None. It doesn't need Accessibility or Screen Recording. It does use a private Apple framework for brightness control (see above).

## Caveats

- **Brief flicker on lid-open.** When you open the lid, macOS wakes the panel to a minimum-visible brightness for a moment before the tool re-dims it to black. Inherent to the brightness approach.
- **Mirror switch can be slow.** If you connect the external while in *extended* mode, the tool forces a switch to mirror mode — a full display reconfiguration that takes a second or two and may flash. If you're already mirroring, this step is skipped.
- **Restored brightness follows auto-brightness.** Because we re-enable auto-brightness on disconnect, the built-in comes back at whatever brightness the ambient light sensor decides, not a fixed value.
- **Private API risk.** Brightness control relies on a private framework that Apple can change in any macOS update. If that happens the tool will report "brightness control unavailable" rather than fail silently.
- **Tested on:** Apple Silicon MacBook Pro (macOS 26) with an Apple Studio Display, in clamshell/mirror setups. Intel Macs, HDMI/DisplayPort monitors, multiple external displays, and other macOS versions are **not yet tested** — feedback welcome.

## License

MIT — see [LICENSE](LICENSE).

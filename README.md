<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
  <img src="docs/logo-light.png" alt="" width="104">
</picture>

<h3>μStats</h3>

An ultra lightweight macOS system monitor.

<hr width="140">

</div>

μStats is a system monitor for the Mac menu bar. It reads CPU, memory, GPU, network,
disk, battery, temperature, process and host statistics from the kernel and shows them in
three places: the menu bar itself, a panel that drops down when you click the status item,
and a desktop widget you can leave on screen.

It is built to be genuinely light. A menu bar monitor runs all day, every day, so μStats
holds a few megabytes and a fraction of a percent of one core rather than the tens of
megabytes its peers take. It has no Dock icon, and reads the system through Mach, IOKit,
sysctl and CoreWLAN.

## Origins

μStats is a fork of [AirStats](https://github.com/byrencheema/airstats) by Byren Cheema,
released under the MIT license. It started from AirStats and went its own way: a
menu bar battery that matches the system one, sharper rendering across mixed-resolution
displays, a redesigned panel with grouped cards, a summary line that names what is wrong
and who is causing it, per-process energy, and a Today view of the day's notable events.
Thanks to Byren for the foundation it is built on.

## Requirements

- macOS 14 or later
- Apple silicon

## Install

Releases will be published on GitHub, signed and notarized, together with a Homebrew
cask. Until then, build it from source.

μStats updates itself with [Sparkle](https://sparkle-project.org) from its GitHub
releases, and installs a new version only when you say so.

## Command line

The app's binary doubles as a command-line tool. Homebrew links it as `mustats`;
from a source build, link it yourself:

```sh
ln -s /Applications/muStats.app/Contents/MacOS/muStats /usr/local/bin/mustats
```

```sh
mustats status            # every module, one line each
mustats cpu --json        # one module, as numbers for scripts
mustats top -n 5 --sort energy
mustats watch network     # refresh in place, Ctrl-C to stop
```

Rates (CPU, network, disk) are measured over one second, so each command takes
about a second to answer. The menu bar app is never started.

## Build from source

You need Xcode 26 or later: the app draws Liquid Glass, which needs the macOS 26 SDK.

```sh
Scripts/build.sh release
ditto .build/out/Products/Release/muStats.app /Applications/muStats.app
open /Applications/muStats.app
```

`Scripts/build.sh` wraps the SwiftPM binary in a `.app` bundle, copies `Sparkle.framework`
into `Contents/Frameworks`, and signs it ad hoc. macOS grants a status item only to a
signed bundle with `LSUIElement` set. Run the script with no argument for a debug build.

An ad-hoc signature is enough to run a build you made yourself, and not enough to travel:
macOS refuses an ad-hoc bundle that arrived over the internet. `Scripts/release.sh` is what
produces the download above, signing with a Developer ID certificate and stapling Apple's
notarization ticket to the `.dmg`.

## Source layout

| Path | What lives there |
| --- | --- |
| `Sources/MuStatsKit` | Collectors, the sampling engine, settings, formatting. No UI. |
| `Sources/MuStatsUI` | Menu bar drawing, panel, desktop widget, settings window, charts, design system. |
| `Sources/MuStats` | The executable, app delegate, and the probe and render commands. |
| `Tests/MuStatsKitTests` | Contract tests for the collectors, plus settings and formatting. |
| `Scripts/build.sh` | Builds the binary and assembles the `.app`. |
| `Scripts/release.sh` | Signs, notarizes and packages the `.dmg` for release. |
| `Scripts/appcast.py` | Writes a release into the appcast Sparkle reads. |
| `Scripts/benchmark.py` | Samples the menu bar monitors on your Mac over one shared window. |

`MuStatsKit` never imports SwiftUI or AppKit, which is what lets the tests and the probe
run in a windowless process.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the checks to run before a pull request and the
house rules.

## Contact

Bugs and feature requests go on the GitHub issue tracker.

## License

MIT. See [LICENSE](LICENSE), which keeps the original AirStats copyright as the license requires.

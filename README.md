<img src="docs/icon.png" width="128" alt="">

# DJI Mic Bar

A macOS menu bar app, styled like the AirPods menu, for the **DJI Mic Mini / Mic Mini 2** wireless
microphone when its receiver is plugged into your Mac over USB.

![Menu bar states](docs/screenshots/menubar-states.png)

<p>
  <img src="docs/screenshots/panel-linked-light.png" width="300" alt="Panel, mic linked (light)">
  <img src="docs/screenshots/panel-two-mics-dark.png" width="300" alt="Panel, two mics (dark)">
</p>

It shows:

- **Transmitter battery** (7 steps, as reported by the receiver) and charging state, per linked mic
- **What's connected**: mic(s) linked to the receiver, receiver on USB, charging case on USB
- **Live input level** per mic
- **Settings you can change from the panel**: low cut, voice tone, clipping control (mic);
  mono/stereo, output gain, safety track (receiver). Noise cancellation is shown but read-only: on a
  Mic Mini 2 kit the receiver doesn't accept it, so use the button on the mic.

The app talks to the receiver's vendor USB interface (libusb, statically linked) using the same
commands as dji-mic-mo. It does not change the USB configuration or touch the audio interface, so
the mic keeps working as a normal audio input. A changed setting shows once the receiver reports the
new value, usually within a second.

## Requirements

- macOS 14+ (built and tested on macOS 27, Apple silicon)
- DJI Mic Mini or Mic Mini 2 receiver connected by USB-C. Other DJI Mic receivers that
  [dji-mic-mo](https://github.com/usokawa/dji-mic-mo) supports (Mic series mobile receiver, Mini 2S)
  should work but are untested.
- Xcode command line tools and `brew install libusb` to build

## Build and run

```sh
brew install libusb
./build.sh                 # -> build/DJIMicBar.app (ad-hoc signed)
./build.sh --install       # build, replace "/Applications/DJI Mic Bar.app" and start it
```

Install it to find it in Spotlight or Alfred and to use **Open at Login**. It's a menu bar app, so
launching it only adds the mic icon to the menu bar; no window opens.

The app icon is committed as `Resources/AppIcon.icns` and packaged by every build. To change it,
edit `tools/make-icon.swift` and regenerate:

```sh
swift tools/make-icon.swift Resources/AppIcon.icns docs/icon.png
```

## Debug modes

```sh
BIN=build/DJIMicBar.app/Contents/MacOS/DJIMicBar
$BIN --dump                  # read the receiver for 5 s, print parsed state as JSON
$BIN --log                   # print a timestamped line on every state change (until Ctrl-C)
$BIN --set lowCut=off        # change one setting and wait for the receiver to confirm it
                             # keys: lowCut, clippingControl, voiceTone (regular|rich|bright,
                             # --slot N for mic N), stereo, gain (-12|-6|0|6|12), safetyTrack
$BIN --snapshot /tmp/snap    # render the panel from live data to PNGs
$BIN --screenshots docs/screenshots   # render README screenshots from demo states
$BIN --glyphs /tmp/glyphs.png         # render all icon variants
```

## Limitations

- **One app at a time.** Only one process can hold the receiver's control interface. Quit DJI Mic
  Bar before using the DJI web tool or `dji-mic-mo.py`, and the other way round.
- **Mic in the case shows as "not linked".** The transmitter powers off when docked, so the receiver
  stops reporting it.
- **No case battery.** Over USB the charging case only answers a firmware "get version" request and
  sends a heartbeat. Its battery level isn't exposed, so the app only shows whether the case is on USB.
- **Battery scale.** The receiver reports 7 steps; per dji-mic-mo, 1 = full and 7 = empty.

## Credits

Protocol parsing is ported from [usokawa/dji-mic-mo](https://github.com/usokawa/dji-mic-mo)
(BSD 2-Clause, see [`THIRD_PARTY_LICENSE-dji-mic-mo.md`](THIRD_PARTY_LICENSE-dji-mic-mo.md)).

DJI Mic Bar is an unofficial project and is not affiliated with or endorsed by DJI. "DJI" and
"DJI Mic" are trademarks of SZ DJI Technology Co., Ltd.

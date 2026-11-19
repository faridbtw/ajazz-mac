# ajazz-mac

A macOS utility for the wired Ajazz AK820 with USB ID `320F:505B`. It reads the keyboard’s current configuration directly over USB.

- **Keys** remaps the normal layer to keys, shortcuts, media actions, and mouse actions.
- **Lights** controls effects, brightness, color, and per-key RGB. In solid Static mode, **One key color** keeps the other keys’ current color and switches to Per key mode.
- **Settings** controls polling rate, debounce, and supported keyboard behavior. The last saved profile can be sent again.
- **Music mode** visualizes system audio on the keyboard when macOS grants audio capture access.

The wired AK820 has no screen. This release targets its wired EVision protocol and has no support for the AK820 Pro, separate Fn-layer editing, or text macros.

## Install

Download the DMG from [Releases](https://github.com/faridbtw/ajazz-mac/releases), open it, and drag **ajazz-mac** to Applications. The universal build requires macOS 14.2 or later. The release is ad-hoc signed and is not notarized, so macOS may block the first launch. See [Apple’s guidance on opening an app from an unidentified developer](https://support.apple.com/en-us/102445).

If the app displays **Permission needed**, use **Open Input Monitoring**, enable **ajazz-mac**, and choose **Quit & Reopen** if prompted. A locally signed update can require you to approve the new build again.

## Build

With Xcode or the Command Line Tools installed, run `./build.sh`. It builds `build/ajazz-mac.app` for Apple Silicon and Intel.

## Credits

The editor and audio spectrum helper are adapted from the MIT-licensed [ak820-mac](https://github.com/gha-projects/ak820-mac). The wired AK820 protocol and matrix layout were cross-checked against [ak820-rs](https://github.com/deddroid/ak820-rs). Their license notices are included in [Editor](Editor).

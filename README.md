# Luma

**Light, beautifully controlled.**

English · [简体中文](README.zh-CN.md)

A lightweight macOS menu bar app for BenQ iScreenBar, with a refined interface, customizable lighting scenes, hold-to-dim keyboard shortcuts, and idle-based lighting automation.

[Download the latest release](https://github.com/chenxicraft/Luma/releases/latest)

## What makes Luma different

- **A more intuitive interface.** Redesigned controls and settings with Liquid Glass on supported macOS versions. Customize scene names, icons, brightness, and color temperature; scene changes save immediately.
- **A quieter menu bar presence.** A dedicated monochrome menu bar symbol keeps controls close at hand. No Dock icon.
- **Brightness shortcuts that work your way.** Use `Fn + F1 / F2` by default, or choose your own key combinations. Hold a shortcut to keep adjusting brightness instead of pressing it repeatedly. Shortcut changes take effect after saving.
- **More flexible idle lighting.** Supplement the lamp’s hardware presence detection with keyboard-and-mouse idle timers ranging from **5 seconds to 30 minutes**. Resume activity to restore the previous lighting state.

## Features

- Power, brightness, color temperature, automatic brightness, and video mode.
- Create, duplicate, edit, and delete lighting scenes.
- Apply a scene when a linked app launches or becomes active.
- Hardware presence detection with 3 / 5 / 10-minute delays and three sensitivity levels.
- Optional sleep/wake, camera-use, and Night Shift automation.
- Local USB HID control with no account required.

The current app interface is in Simplified Chinese. English documentation does not imply an English app localization.

## Installation

Download the DMG or ZIP from [Releases](https://github.com/chenxicraft/Luma/releases/latest), then move `Luma.app` to Applications. Quit the original iScreenBar app before starting Luma to avoid competing lighting commands.

Release builds require **macOS 14 or later** and include Apple Silicon and Intel binaries. Intel and older macOS versions have not been tested on physical machines. macOS 26 and later use Liquid Glass; older systems use compatible materials.

Builds are currently **ad-hoc signed and not notarized by Apple**. If macOS blocks the app, verify the download source and check System Settings → Privacy & Security for an Open Anyway option. There is no need to disable system security. See [Apple’s instructions](https://support.apple.com/102445).

## Compatibility and limitations

- Currently matches USB VID/PID `04A5:2501`. Compatibility with every ScreenBar model or hardware revision is not guaranteed.
- Keyboard/mouse inactivity is **not** human presence detection. Reading or watching a video can trigger idle shutoff. Hardware detection delays remain unchanged.
- Luma does not unlock brightness below the lamp’s hardware minimum.
- Night Shift integration uses a non-public system interface and may be affected by macOS updates.
- Camera and sleep/wake automation need broader real-world device testing.
- Firmware updates, automatic app updates, and diagnostic uploads are not included.

## Build from source

Requires macOS and Xcode command-line tools.

```sh
./source/build.command              # Host architecture; macOS 12 deployment target
./source/build.command --universal  # arm64 + x86_64; macOS 14 deployment target
```

The build creates `Luma.app` in the repository root and applies an ad-hoc signature. These deployment targets are not a claim of testing on every supported OS version.

Run isolated tests with a simulated device:

```sh
./Luma.app/Contents/MacOS/Luma --selftest
./Luma.app/Contents/MacOS/Luma --ui-test
```

## Privacy

Scenes and app bindings stay in local user preferences and are not included in release packages. Luma does not integrate usage analytics or log uploads. Camera automation checks camera-use status without capturing or recording images.

Luma is an independent project and is not affiliated with BenQ. iScreenBar belongs to its respective owner.

Designed by Chenxi.

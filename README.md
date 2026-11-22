<p align="center">
  <img src="icon/preview.png" width="128" height="128" alt="TabLite app icon">
</p>

<h1 align="center">TabLite</h1>

<p align="center">
  <b>A tiny, instant window switcher for macOS, with a live preview of every window.</b><br>
  One Swift file. No dependencies. Fast even on old Intel MacBooks.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-10.15%2B-111111" alt="macOS 10.15+">
  <img src="https://img.shields.io/badge/Intel%20%2B%20Apple%20Silicon-universal-5b5bd6" alt="Universal: Intel and Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-5.9-f05138?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-GPL--3.0-2f80ed" alt="License: GPL-3.0">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.jpg">
    <img src="docs/screenshot-light.jpg" width="900" alt="TabLite's glass panel showing live previews of five open windows, with the second one selected">
  </picture>
  <br>
  <sub>Illustration</sub>
</p>

---

## Highlights

- **Instant.** The panel opens right away and never waits for screenshots. A quick tap switches without drawing anything.
- **Every window, not just every app.** Two browser windows are two tiles.
- **Live previews.** See what's in each window before you switch to it.
- **Glass that fits your Mac.** Liquid Glass on macOS 26 and frosted glass on older versions. Follows Light and Dark mode.
- **Featherweight.** No CPU use while idle: no polling, no timers, no background work.
- **Private.** No network access, no analytics, no accounts.

## Usage

| Keys | Action |
|---|---|
| Hold **⌥ Option**, press **Tab** | Open the switcher, then move to the next window |
| **⇧ Shift+Tab** &nbsp;/&nbsp; **← →** | Previous / next window |
| **↑ ↓** | Move between rows |
| Release **⌥ Option** | Switch to the selected window |
| **Esc** | Cancel |
| Click a preview | Switch to that window |

A quick tap of the shortcut jumps straight back to your previous window.

## Install

TabLite is built from source. You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Lucifix/TabLite.git
cd TabLite
./build.sh
open TabLite.app
```

The build is universal (Intel + Apple Silicon). Move `TabLite.app` to `/Applications` to keep it.

### Permissions

On first launch, allow TabLite in **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| **Accessibility** | Catch the shortcut and bring the chosen window to the front |
| **Screen Recording** | Window previews and titles. Without it, you get app icons and names |

Then choose **Restart TabLite** from its menu bar icon.

## Why it's fast

- **Zero idle cost.** A single keyboard event tap; nothing runs until you press the shortcut.
- **One system call** builds the window list (~3 ms), in front-to-back order, which matches recent use.
- **The UI never waits.** The panel appears with cached previews. Fresh ones are captured in the background, selected window first, and swapped in as they arrive.
- **Small previews.** Previews are kept at tile size, not full resolution.
- **Warm start.** The one-time setup cost (~300 ms) is paid at launch, not the first time you switch.
- **GPU-friendly drawing.** Plain Core Animation layers with no animations. The glass is the system's own blur, rendered by macOS on the GPU.

## Compatibility

| macOS | Glass | Window previews | Status |
|---|---|---|---|
| 26 Tahoe and later | Liquid Glass | ScreenCaptureKit | Untested |
| 14 – 15 | Frosted glass | ScreenCaptureKit | Untested |
| 10.15 – 13 | Frosted glass | CGWindowListCreateImage | Tested on macOS 13 (Intel) |

On macOS 14 or later? Please [open an issue](https://github.com/Lucifix/TabLite/issues) and say whether it works for you, ideally with a screenshot.

## Development

<details>
<summary><b>Keep permissions across rebuilds</b></summary>

<br>

macOS ties permissions to the app's code signature. Without a certificate, every build gets a new signature and you must grant permissions again. Create a free self-signed certificate once:

1. Open **Keychain Access**, then in the menu bar choose **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `TabLite Dev` · Identity Type: **Self-Signed Root** · Certificate Type: **Code Signing** → **Create**

`build.sh` uses it automatically. Set `TABLITE_SIGN` to use a certificate with a different name.

</details>

<details>
<summary><b>Project layout</b></summary>

<br>

| Path | What |
|---|---|
| `main.swift` | The whole app |
| `build.sh` | Builds and signs `TabLite.app` |
| `icon/make_icon.swift` | Draws the app icon in code. Regenerate with `swift icon/make_icon.swift` |
| `docs/screenshot.html` | Source of the README illustration. Re-render with `docs/render-screenshots.sh` |

`TabLite.app/Contents/MacOS/TabLite --list` prints the windows the switcher would show.

</details>

## Limitations

- Shows windows on the current Space only. Minimized windows aren't listed.
- The shortcut is fixed to Option+Tab for now. Another app using Option+Tab will conflict with it.

## License

[GPL-3.0](LICENSE)

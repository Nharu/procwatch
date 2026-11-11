**English** · [한국어](README.ko.md)

# procwatch

<img src="assets/readme/kiwi-walk.gif" alt="procwatch kiwi walking" width="144" height="96">

A macOS menu bar app that finds runaway processes among everything `claude` spawned and tells you about them — it only alerts, it never kills.

It is a standalone monitor, not a plugin or part of Claude Code.

<img src="assets/readme/menu-en.png" alt="procwatch menu bar dropdown" width="551" height="433">

## What it does

### Watch rules

- Target: every descendant process of a `claude` process
- Condition: a process is reported once its awake seconds with smoothed CPU at or above the threshold
  (default 50%, 1 core = 100%) outnumber those below it by a net sustain time (default 30 min).
  Each second below the threshold pays back one second above it.
  It is cleared after 2 min in a row under 80% of the threshold, after paying back to half the
  report bar, or when the process exits. The threshold and sustain time are set from the menu.
- Action: a notification only — nothing is ever terminated

### Menu bar icon

A kiwi sprite walks in the menu bar.

- Normally: a monochrome template image — the system flips it to match the menu bar background
- When a runaway is detected: system red (`NSColor.systemRed`), left to the system for light and dark appearances
- Walking speed follows the CPU usage of the `claude` processes; the walk can be paused from the menu
- The kiwi can be swapped for your own sprite and resized — see [Themes](#themes)

## Install

Apple silicon, macOS 15 or later.

```sh
brew install --cask nharu/tap/procwatch
```

## Build from source

Requires a Swift 6 toolchain — Xcode 16 or later, or the Command Line Tools.

```sh
app/scripts/build-app.sh            # build and sign app/.build/bundle/procwatch.app
app/scripts/build-app.sh --install  # also copy it to /Applications and launch it
```

The script builds an arm64 release binary, assembles the bundle and signs it ad hoc.

## Notifications

procwatch asks for notification permission on first launch. If notifications are turned off, the
menu shows an item that opens the notification settings for procwatch.

## Launch at login

Turn launch at login on or off from the menu. The item is available only when the app is
installed in `/Applications`.

## Themes

The bundled kiwi is the only built-in theme. You can add your own sprites as themes.

- Location: `~/Library/Application Support/procwatch/themes/<name>/` — the folder name is the theme
  name. **Open Themes Folder…** in the menu creates the folder if needed and opens it in Finder.
- Frames: four PNG files `00@2x.png`, `01@2x.png`, `02@2x.png`, `03@2x.png`, each exactly 48x32 px
  (@2x). Other files in the folder are ignored.
- Optional `theme.json`: `{"template": true}` draws the theme as a monochrome template image that
  the system flips to match the menu bar; without the file, or with `false`, the frames are drawn in
  their own colors. Unknown fields are ignored.
- Runaway: a color theme is washed with 60% system red; a monochrome theme is filled with system red
  in its own shape, like the kiwi.
- Pick a theme from the **Theme** submenu in the menu. The change applies right away, without a
  restart.
- **Icon size** in the same submenu: Default (kiwi 16 pt, your themes 22 pt), 16 pt, 19 pt or 22 pt,
  applied to every theme including the kiwi.
- **Light outline on dark menu bar**: draws a 1 px light outline around a color theme while the menu
  bar is dark, so dark sprites stay visible.
- If the chosen theme can't be read (a missing or wrong-sized frame, a malformed `theme.json`, a
  deleted folder), the kiwi is shown instead and the menu says so in one line. Your choice is kept,
  and the theme comes back once the folder is fixed — it is checked again each time the menu opens.
- Uninstalling the app does not remove the themes folder.

## Uninstall

First turn off launch at login from the menu, then remove the app:

```sh
brew uninstall --cask procwatch
brew uninstall --zap --cask procwatch   # also delete the settings file
```

If you installed from source:

```sh
app/scripts/build-app.sh --uninstall
```

This quits the app, removes its login item, deletes `/Applications/procwatch.app` and clears its settings.

## Development

```sh
swift test --package-path app
```

| Path | Contents |
|---|---|
| `app/` | Swift package: the app, its core library and tests; build scripts in `app/scripts/` |
| `assets/` | Kiwi frames the app uses (`frames2/kiwi/`), the source sprite pack (`source/kiwi.zip`), its license notes and the README image |
| `packaging/homebrew/` | Homebrew cask template |
| `.github/workflows/` | CI and release workflows |

`docs/` is ignored by git and is not part of the repository. Release procedures are in
[RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE). The kiwi sprites are CC0; the artist and source pack are listed in
[`assets/LICENSE-kiwi-family.md`](assets/LICENSE-kiwi-family.md).

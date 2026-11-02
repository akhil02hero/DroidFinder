# DroidFinder

A Finder-style file browser for Android phones on macOS. Plug your phone in with a USB cable and DroidFinder opens with its files — browse folders, copy things to and from your Mac, and tidy up storage without fighting MTP.

## Features

- Opens automatically when an Android phone is plugged in (lives in the menu bar)
- Four Finder-style views — **Icons, List, Columns and Gallery** (⌘1–⌘4) — with real thumbnails for photos, PDFs and short videos
- Sortable, searchable list with name, date modified, size and kind
- Sidebar shortcuts: Camera, Screenshots, Downloads, Pictures, Documents, Movies, Music, WhatsApp Media
- Storage usage at a glance
- Double-click a file to open it on your Mac
- Copy phone → Mac (toolbar, right-click, or drag rows into Finder)
- Copy Mac → phone (toolbar or drag files from Finder into the window)
- New folder, rename, delete (with confirmation)
- Back / forward / enclosing folder, with ⌘[ ⌘] ⌘↑ shortcuts
- Optional Open at Login

## Requirements

- macOS 14 Sonoma or later
- `adb` (Android platform tools):
  ```bash
  brew install android-platform-tools
  ```
- On the phone: **Settings → Developer options → USB debugging** turned on, and **Allow** tapped on the prompt the first time you connect

## Build

Needs Swift 5.10+ (Xcode or the Command Line Tools).

```bash
./build.sh            # builds DroidFinder.app in this folder
./build.sh --install  # also copies it to /Applications
```

The app is ad-hoc signed, so the first time you open a downloaded copy, right-click it and choose **Open**.

## How it works

DroidFinder is a SwiftUI front end over `adb`: folders are listed with `find`/`stat` on the phone, and files move with `adb pull` / `adb push`. Nothing is installed on the phone.

## Tips

- If the phone doesn't show up, quit **Android File Transfer** if you have it — its background agent grabs the phone and blocks `adb`.
- Samsung phones: turn off **Auto Blocker** (Settings → Security and privacy) if USB debugging won't connect.

## License

MIT — see [LICENSE](LICENSE).

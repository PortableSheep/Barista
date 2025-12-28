# Barista (macOS)

A tiny menu-bar “keep awake” app that wraps macOS `/usr/bin/caffeinate`.

## Features

- Menu bar icon + menu toggle (Enable/Disable)
- Duration (Indefinitely / 15m / 30m / 1h / 2h)
- Option to **allow the display to sleep** (disable “Keep Display Awake”)

Under the hood it runs `caffeinate` with:
- `-i` always (prevents idle sleep)
- optional `-d` (prevents display sleep)
- optional `-t <seconds>` (timeout)

## Build a .app

From the repo:

```bash
cd Barista
bash scripts/build_app.sh
open dist/Barista.app
```

## Install (from GitHub Releases)

By default this builds from source and installs into `/Applications`.

```bash
curl -fsSL https://raw.githubusercontent.com/PortableSheep/Barista/main/scripts/install.sh | bash
```

If you don’t have an Apple Developer account (no signing/notarization), the local build install is usually the smoothest option:

```bash
curl -fsSL https://raw.githubusercontent.com/PortableSheep/Barista/main/scripts/install.sh | INSTALL_METHOD=source bash
```

Optional (downloads the latest prebuilt zip from GitHub Releases):

```bash
curl -fsSL https://raw.githubusercontent.com/PortableSheep/Barista/main/scripts/install.sh | INSTALL_METHOD=release bash
```
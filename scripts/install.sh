#!/usr/bin/env bash
set -euo pipefail

# Barista installer (macOS)
#
# Two install modes:
# - INSTALL_METHOD=source (default): git clone + local build, then install to /Applications.
#   This typically avoids the downloaded-app quarantine problem because the app is built locally.
# - INSTALL_METHOD=release: download the latest GitHub Release asset (Barista-macos.zip) and install it.
#
# IMPORTANT:
# - This script does NOT attempt to bypass macOS security features (Gatekeeper/quarantine).
# - For a smooth “no warnings” install experience for non-dev users, ship a code-signed + notarized app.

REPO_DEFAULT="PortableSheep/Barista"
REPO="${REPO:-$REPO_DEFAULT}"
ASSET_NAME="${ASSET_NAME:-Barista-macos.zip}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_METHOD="${INSTALL_METHOD:-source}" # source | release
REF="${REF:-}" # optional git ref (tag/branch/sha) when INSTALL_METHOD=source

have() { command -v "$1" >/dev/null 2>&1; }

if ! have curl && ! have wget; then
  echo "Error: need curl or wget" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

download() {
  local url="$1"
  local out="$2"
  if have curl; then
    curl -fL --retry 3 --retry-delay 1 -o "$out" "$url"
  else
    wget -O "$out" "$url"
  fi
}

install_app_to_applications() {
  local app_path="$1"
  local dest_app="$INSTALL_DIR/Barista.app"

  echo "Installing to: $dest_app"
  rm -rf "$dest_app"
  cp -R "$app_path" "$dest_app"

  if have codesign; then
    if codesign --verify --deep --strict --verbose=2 "$dest_app" >/dev/null 2>&1; then
      echo "codesign: OK"
    else
      echo "codesign: NOT VERIFIED"
      echo "Note: unsigned downloads may be blocked by Gatekeeper on first open."
    fi
  fi

  if have spctl; then
    spctl -a -vv "$dest_app" 2>/dev/null || true
  fi

  # Remove quarantine attribute to avoid Gatekeeper warnings
  if have xattr; then
    xattr -rd com.apple.quarantine "$dest_app" 2>/dev/null || true
  fi
}

install_from_source() {
  if ! have git; then
    echo "Error: INSTALL_METHOD=source requires git" >&2
    exit 1
  fi

  if ! have swift; then
    echo "Error: INSTALL_METHOD=source requires Swift toolchain (Xcode Command Line Tools)" >&2
    echo "Install with: xcode-select --install" >&2
    exit 1
  fi

  SRC_DIR="$TMP_DIR/src"
  echo "Cloning https://github.com/$REPO.git"
  git clone --depth 1 "https://github.com/$REPO.git" "$SRC_DIR" >/dev/null

  if [[ -n "$REF" ]]; then
    echo "Checking out: $REF"
    git -C "$SRC_DIR" fetch --depth 1 origin "$REF" >/dev/null 2>&1 || true
    git -C "$SRC_DIR" checkout -q "$REF"
  fi

  # Support repos where Barista is either at repo root or under ./Barista
  if [[ -x "$SRC_DIR/Barista/scripts/build_app.sh" ]]; then
    APP_ROOT="$SRC_DIR/Barista"
  elif [[ -f "$SRC_DIR/Barista/scripts/build_app.sh" ]]; then
    APP_ROOT="$SRC_DIR/Barista"
  elif [[ -x "$SRC_DIR/scripts/build_app.sh" ]]; then
    APP_ROOT="$SRC_DIR"
  elif [[ -f "$SRC_DIR/scripts/build_app.sh" ]]; then
    APP_ROOT="$SRC_DIR"
  else
    echo "Error: could not locate scripts/build_app.sh in repo" >&2
    exit 1
  fi

  echo "Building locally (this avoids downloaded-app quarantine in most cases)..."
  (cd "$APP_ROOT" && bash scripts/build_app.sh)

  BUILT_APP="$APP_ROOT/dist/Barista.app"
  if [[ ! -d "$BUILT_APP" ]]; then
    echo "Error: build did not produce dist/Barista.app" >&2
    exit 1
  fi

  install_app_to_applications "$BUILT_APP"
}

install_from_release() {
  if ! have unzip; then
    echo "Error: INSTALL_METHOD=release requires unzip" >&2
    exit 1
  fi

  API_URL="https://api.github.com/repos/$REPO/releases/latest"

  if have curl; then
    JSON="$(curl -fsSL "$API_URL")"
  else
    JSON="$(wget -qO- "$API_URL")"
  fi

  # Extract browser_download_url for the desired asset name using a minimal parser.
  # Assumes the release includes an asset named exactly $ASSET_NAME.
  DOWNLOAD_URL="$(printf '%s' "$JSON" | awk -v name="$ASSET_NAME" '
    $0 ~ "\"name\": \""name"\"" {found=1}
    found && $0 ~ "\"browser_download_url\"" {
      gsub(/.*\"browser_download_url\": \"/, "");
      gsub(/\".*/, "");
      print;
      exit
    }
  ')"

  if [[ -z "${DOWNLOAD_URL:-}" ]]; then
    echo "Error: could not find asset '$ASSET_NAME' in latest release for $REPO" >&2
    echo "Make sure the GitHub Action uploaded $ASSET_NAME to the release." >&2
    exit 1
  fi

  ZIP_FILE="$TMP_DIR/$ASSET_NAME"
  EXTRACT_DIR="$TMP_DIR/extract"
  mkdir -p "$EXTRACT_DIR"

  echo "Downloading: $DOWNLOAD_URL"
  download "$DOWNLOAD_URL" "$ZIP_FILE"

  echo "Extracting..."
  unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"

  APP_PATH="$EXTRACT_DIR/Barista.app"
  if [[ ! -d "$APP_PATH" ]]; then
    # Some zip tools nest in a folder; try to locate it.
    APP_PATH_FOUND="$(find "$EXTRACT_DIR" -maxdepth 3 -name "Barista.app" -type d | head -n 1 || true)"
    if [[ -z "$APP_PATH_FOUND" ]]; then
      echo "Error: Barista.app not found in zip" >&2
      exit 1
    fi
    APP_PATH="$APP_PATH_FOUND"
  fi

  install_app_to_applications "$APP_PATH"
}

case "$INSTALL_METHOD" in
  source)
    install_from_source
    ;;
  release)
    install_from_release
    ;;
  *)
    echo "Error: unknown INSTALL_METHOD '$INSTALL_METHOD' (use 'source' or 'release')" >&2
    exit 1
    ;;
esac

echo "Done."
echo "If macOS blocks it: right-click Barista.app -> Open, then confirm Open."

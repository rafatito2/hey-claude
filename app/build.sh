#!/bin/zsh
# Compila Claude Voice en ~/claude-voice/ClaudeVoice.app
set -e
cd "$(dirname "$0")"
APP="$HOME/claude-voice/ClaudeVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -framework AppKit -framework Speech -framework AVFoundation -framework Carbon \
  -o "$APP/Contents/MacOS/ClaudeVoice" main.swift
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP"
echo "Listo: $APP"

#!/bin/bash
# Install build/SilenceCut.app into ~/Applications and register the extension with macOS.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf ~/Applications/SilenceCut.app && mkdir -p ~/Applications
cp -R build/SilenceCut.app ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted ~/Applications/SilenceCut.app
pluginkit -a ~/Applications/SilenceCut.app/Contents/PlugIns/SilenceCutExt.appex
pluginkit -e use -i com.nathan.silencecut.extension
echo "Installé. Relancez Final Cut Pro (Fenêtre > Extensions > SilenceCut)."

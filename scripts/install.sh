#!/bin/sh
# Builds Monoword and installs it as ~/Applications/Monoword.app, then starts it.
# A running copy is stopped first (only the process whose executable is that exact path); the old
# bundle goes to .trash/ in this project, never deleted. Same signing identity, so the
# Accessibility permission and the login item carry over.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
DEST="$HOME/Applications/Monoword.app"
EXE="$DEST/Contents/MacOS/Monoword"

./scripts/build-app.sh

PID=$(ps -axo pid=,comm= | awk -v exe="$EXE" '$2 == exe {print $1}')
if [ -n "$PID" ]; then
  echo "Stopping running Monoword (pid $PID: $EXE)"
  kill "$PID"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.2
  done
fi
mkdir -p "$HOME/Applications" "$ROOT/.trash"
if [ -e "$DEST" ]; then mv "$DEST" "$ROOT/.trash/Monoword.app.installed.$(date +%s)"; fi
ditto build/Monoword.app "$DEST"
codesign --verify --strict "$DEST"

# Register with Launch Services (URL scheme) and refresh the Services menu.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
/System/Library/CoreServices/pbs -update

if [ -z "$MONOWORD_NO_LAUNCH" ]; then open "$DEST"; fi
echo "Installed $DEST (commit $(plutil -extract SRBuildCommit raw "$DEST/Contents/Info.plist"))"

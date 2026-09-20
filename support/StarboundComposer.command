#!/bin/bash
# Finder cannot open an ad-hoc signed bundle on macOS 26+ — double-click this instead.
# It launches the same executable directly, detached from the Terminal.
exec "$HOME/Applications/StarboundComposer.app/Contents/MacOS/StarboundComposer" >/dev/null 2>&1 &
disown

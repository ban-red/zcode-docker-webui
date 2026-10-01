#!/usr/bin/env bash
# Completes ZCode's OAuth login: opens the login page in your browser (macOS `open`, Linux
# `xdg-open`, else prints it), then hands the zcode:// callback URL back to the app in the container.
#   ./login.sh         log in the desktop app
#   ./login.sh --cli   log in ZCode's headless CLI (behind /api/v1) on its own; normally not needed,
#                      since zcode-cli-sync reuses the desktop's login

set -euo pipefail

open_url() {
    if [[ $OSTYPE == darwin* ]]; then open "$1"
    elif command -v xdg-open >/dev/null; then xdg-open "$1" >/dev/null 2>&1 &
    else echo "Open in your browser: $1"
    fi
}
clipboard() {
    if [[ $OSTYPE == darwin* ]]; then pbpaste
    elif command -v wl-paste >/dev/null; then wl-paste --no-newline
    elif command -v xclip >/dev/null; then xclip -o -selection clipboard
    fi
}

docker inspect -f '{{.State.Running}}' zcode 2>/dev/null | grep -q true \
    || { echo "ZCode container isn't running. Start it with ./run.sh first." >&2; exit 1; }

if [[ ${1:-} == --cli ]]; then
    # The CLI finishes OAuth through Z.ai's own callback and waits for it, so no URL pasting.
    # Only Z.ai login pages are opened; anything else the container prints is just shown.
    docker exec -i zcode zcode-cli login --no-browser | while IFS= read -r line; do
        printf '%s\n' "$line"
        [[ $line =~ ^https://(chat\.)?z\.ai/ ]] && open_url "$line"
    done
    exit "${PIPESTATUS[0]}"
fi

echo "Waiting for ZCode to request login (click Login in ZCode)..."
url=$(docker exec zcode sh -c 'f=/tmp/zcode-open-url; until [ -s $f ]; do sleep 0.2; done; cat $f; rm -f $f')
open_url "$url"

echo ""
echo "Log in, then copy the zcode://zai-auth/callback... URL"
echo "(the browser can't open it: right-click → Inspect → Console, or copy it from the address bar)."
echo ""
read -r -p "Paste the callback URL here (or press Enter to use the clipboard): " callback_url
callback_url=${callback_url:-$(clipboard || true)}

if [[ $callback_url != zcode://* ]]; then
    echo "That doesn't look like a zcode:// URL, aborting." >&2
    exit 1
fi

docker exec zcode zcode-callback "$callback_url"
echo "Login handed to ZCode."

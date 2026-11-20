#!/usr/bin/env bash
# Refuses a formula whose url is not exactly the one release download URL it should name.
# Usage: check-url.sh FORMULA WANT_URL. Prints one `release: ...` line to stderr and exits 1.
set -euo pipefail
formula=${1:?usage: check-url.sh FORMULA WANT_URL}
want=${2:?want url}
urls=$(grep -E '^ *url ' "$formula" || true)
[ "$(grep -c . <<<"$urls")" = 1 ] || { echo "release: the formula does not name exactly one url" >&2; exit 1; }
[ "$urls" = "  url \"$want\"" ] || { echo "release: the formula's url is not $want" >&2; exit 1; }

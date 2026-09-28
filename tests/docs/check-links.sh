#!/usr/bin/env bash
# Checks relative links and image paths in README.md and every *.md under docs/.
# A target must exist as a file or directory relative to the file that links it.
# Out of scope: http(s):// and mailto: links, pure in-page anchors (#…).
# Usage: tests/docs/check-links.sh        exit 0 = every link resolves, 1 = broken links listed
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2

broken=0
files=0
for file in README.md $(find docs -name '*.md' | sort); do
  files=$((files + 1))
  # Markdown links and images: ](target) or ](target "title")
  targets=$(grep -o '\]([^)]*)' "$file" | sed -e 's/^](//' -e 's/)$//' -e 's/ ".*"$//')
  [ -z "$targets" ] && continue
  while IFS= read -r target; do
    case "$target" in
      ''|http://*|https://*|mailto:*|\#*) continue ;;
    esac
    path=${target%%#*}
    if [ ! -e "$(dirname "$file")/$path" ]; then
      echo "$file: $target"
      broken=$((broken + 1))
    fi
  done <<< "$targets"
done

echo "check-links: $files markdown files, $broken broken link(s)"
[ "$broken" -eq 0 ]

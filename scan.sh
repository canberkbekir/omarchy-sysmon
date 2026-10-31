#!/usr/bin/env bash
# wartafak.sysmon folder scan
# Prints one JSON object: home folder sizes in bytes, biggest first, plus
# their total. Walks every file, so it only runs when the Storage tab opens,
# at the lowest CPU and disk priority. Exits non-zero when nothing was read.
set -u

cd "$HOME" || exit 1
shopt -s dotglob nullglob

dirs=()
for d in *; do
  [ -d "$d" ] && [ ! -L "$d" ] && dirs+=("./$d")
done
[ "${#dirs[@]}" -gt 0 ] || exit 1

# "<bytes> ./name" per folder. The ./ prefix also keeps dua's own "total"
# line apart from a folder that happens to be called total.
sizes() {
  if command -v dua >/dev/null 2>&1; then
    timeout 120 nice -n 19 ionice -c3 dua -x -f bytes "${dirs[@]}" 2>/dev/null \
      | sed -n 's/^ *\([0-9][0-9]*\) b \(\.\/.*\)$/\1 \2/p'
  else
    timeout 120 nice -n 19 ionice -c3 du -xsB1 "${dirs[@]}" 2>/dev/null \
      | sed -n 's/^\([0-9][0-9]*\)\t\(\.\/.*\)$/\1 \2/p'
  fi
}

rows="$(sizes | sort -rn)"
[ -n "$rows" ] || exit 1

printf '%s\n' "$rows" | awk '
  {
    bytes = $1
    name = substr($0, length($1) + 4)
    gsub(/\\/, "\\\\", name)
    gsub(/"/, "\\\"", name)
    total += bytes
    list = list (NR > 1 ? "," : "") "{\"name\":\"" name "\",\"bytes\":" bytes "}"
  }
  END { printf "{\"total\":%.0f,\"folders\":[%s]}\n", total, list }'

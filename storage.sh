#!/usr/bin/env bash
# wartafak.sysmon storage reader
# Prints one JSON array with one entry per local device: mount, filesystem,
# encrypted flag, size/used/avail bytes, df's use% and the other mounts that
# share the device. df reads filesystem counters, nothing is scanned.
set -u

declare -A mount shared row
order=()

while read -r src fstype size used avail pct target; do
  if [ -z "${mount[$src]+x}" ]; then
    order+=("$src")
    mount[$src]="$target"
    shared[$src]=""
    row[$src]="$fstype $size $used $avail ${pct%\%}"
  elif [ "${#target}" -lt "${#mount[$src]}" ]; then
    # Keep the shortest mount as the name, e.g. / over /var/log.
    shared[$src]+="${mount[$src]}"$'\t'
    mount[$src]="$target"
  else
    shared[$src]+="$target"$'\t'
  fi
done < <(timeout 5 df -l -B1 -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay \
  --output=source,fstype,size,used,avail,pcent,target 2>/dev/null | tail -n +2)

json_str() { printf '"%s"' "$(printf '%s' "$1" | tr -d '"\\')"; }

printf '['
sep=""
for src in ${order[@]+"${order[@]}"}; do
  read -r fstype size used avail pct <<< "${row[$src]}"
  encrypted=false
  [ "$(lsblk -ndo TYPE "$src" 2>/dev/null)" = "crypt" ] && encrypted=true

  also=""
  IFS=$'\t' read -r -a others <<< "${shared[$src]}"
  for m in ${others[@]+"${others[@]}"}; do
    also+="${also:+,}$(json_str "$m")"
  done

  printf '%s{"mount":%s,"fstype":%s,"encrypted":%s,"size":%s,"used":%s,"avail":%s,"pct":%s,"shared":[%s]}' \
    "$sep" "$(json_str "${mount[$src]}")" "$(json_str "$fstype")" "$encrypted" "$size" "$used" "$avail" "$pct" "$also"
  sep=","
done
printf ']\n'

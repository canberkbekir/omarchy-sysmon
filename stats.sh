#!/usr/bin/env bash
# wartafak.sysmon stats collector
# Prints one JSON line: cpu%, cpu_temp, gpu%, gpu_temp, gpu fan%, gpu vendor/name, mem%, mem details,
# cpu fan rpm + duty%
# All temps in Celsius. Nullable fields are emitted as null when unavailable.
set -u

cpu_usage() {
  # Two snapshots of /proc/stat ~0.4s apart
  read -r _ a1 b1 c1 d1 e1 f1 g1 h1 _rest < /proc/stat
  sleep 0.4
  read -r _ a2 b2 c2 d2 e2 f2 g2 h2 _rest < /proc/stat
  local idle1=$((d1 + e1)) idle2=$((d2 + e2))
  local total1=$((a1+b1+c1+d1+e1+f1+g1+h1)) total2=$((a2+b2+c2+d2+e2+f2+g2+h2))
  local dtotal=$((total2 - total1)) didle=$((idle2 - idle1))
  if [ "$dtotal" -le 0 ]; then echo "null"; return; fi
  awk -v a="$dtotal" -v b="$didle" 'BEGIN{printf "%.1f", (a-b)*100.0/a}'
}

cpu_temp() {
  local t=""
  # 1) coretemp package sensor via hwmon
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] || continue
    if [ "$(cat "$h/name" 2>/dev/null)" = "coretemp" ]; then
      for l in "$h"/temp*_label; do
        if [ -f "$l" ] && grep -qi "package" "$l" 2>/dev/null; then
          local f="${l%_label}_input"
          [ -f "$f" ] && t="$(cat "$f" 2>/dev/null)" && break
        fi
      done
      [ -n "$t" ] && break
    fi
  done
  # 2) x86_pkg_temp thermal zone
  if [ -z "$t" ]; then
    for z in /sys/class/thermal/thermal_zone*; do
      [ -f "$z/type" ] || continue
      if [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ] && [ -f "$z/temp" ]; then
        t="$(cat "$z/temp" 2>/dev/null)"
        break
      fi
    done
  fi
  # 3) k10temp / zenpower hwmon
  if [ -z "$t" ]; then
    for h in /sys/class/hwmon/hwmon*; do
      [ -f "$h/name" ] || continue
      local n="$(cat "$h/name" 2>/dev/null)"
      if [ "$n" = "k10temp" ] || [ "$n" = "zenpower" ]; then
        [ -f "$h/temp1_input" ] && t="$(cat "$h/temp1_input" 2>/dev/null)" && break
      fi
    done
  fi
  # 4) lm-sensors fallback
  if [ -z "$t" ] && command -v sensors >/dev/null 2>&1; then
    t="$(sensors 2>/dev/null | awk '/Package id 0:/{gsub(/[^0-9.]/,"",$4); print $4*1000; exit} /Tctl:/{gsub(/[^0-9.]/,"",$2); print $2*1000; exit} /edge:/{gsub(/[^0-9.]/,"",$2); print $2*1000; exit}')"
  fi
  if [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then
    awk -v v="$t" 'BEGIN{printf "%.1f", v/1000}'
  else
    echo "null"
  fi
}

mem_info() {
  local total avail
  total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null && [ -n "$avail" ]; then
    local used=$((total - avail))
    local pct
    pct="$(awk -v u="$used" -v t="$total" 'BEGIN{printf "%.1f", u*100.0/t}')"
    echo "$pct $used $total"
  else
    echo "null null null"
  fi
}

# Static CPU identity: raw model string, thread count, max boost GHz.
cpu_meta() {
  local model threads maxghz
  model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
  threads="$(nproc 2>/dev/null || grep -c '^processor' /proc/meminfo 2>/dev/null)"
  maxghz=""
  local raw
  raw="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
  if [ -n "$raw" ] && [ "$raw" -gt 0 ] 2>/dev/null; then
    maxghz="$(awk -v v="$raw" 'BEGIN{printf "%.2f", v/1000000}')"
  fi
  [ -n "$threads" ] || threads="null"
  [ -n "$maxghz" ] || maxghz="null"
  model="$(printf '%s' "$model" | tr -d '\"\\' | head -c 100)"
  printf '%s\t%s\t%s\n' "$model" "$threads" "$maxghz"
}

# CPU fan from the motherboard Super I/O (nct668x / nct6775 / it87):
# prints "rpm<TAB>duty%". Prefers a fan labeled "CPU"; else fan1, which is
# the CPU_FAN header on these chips. Duty is pwmN/255 of the same header.
cpu_fan() {
  local rpm="null" duty="null" h n f l idx=""
  for h in /sys/class/hwmon/hwmon*; do
    n="$(cat "$h/name" 2>/dev/null)"
    case "$n" in nct6683|nct6686|nct6687|nct67*|nct6775|nct6779|nct6798|it87*) ;; *) continue ;; esac
    for l in "$h"/fan*_label; do
      [ -f "$l" ] || continue
      if grep -qi "cpu" "$l" 2>/dev/null; then
        idx="$(basename "$l")"; idx="${idx#fan}"; idx="${idx%_label}"
        break
      fi
    done
    [ -n "$idx" ] || idx=1
    f="$h/fan${idx}_input"
    [ -f "$f" ] || { idx=""; continue; }
    rpm="$(tr -dc '0-9' < "$f" 2>/dev/null)"
    [ -n "$rpm" ] || rpm="null"
    if [ -f "$h/pwm$idx" ]; then
      local raw
      raw="$(tr -dc '0-9' < "$h/pwm$idx" 2>/dev/null)"
      [ -n "$raw" ] && duty="$(awk -v v="$raw" 'BEGIN{printf "%.0f", v*100/255}')"
    fi
    break
  done
  printf '%s\t%s\n' "$rpm" "$duty"
}

# Shorten a verbose lspci VGA line to "Vendor Model", e.g.
# "Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [Radeon RX 6650 XT / 6700S / 6800S] (rev c1)"
# -> "AMD Radeon RX 6650 XT"
gpu_short_from_lspci() {
  local line="$1" vendor="$2"
  local inner
  inner="$(printf '%s' "$line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | head -n 1 | cut -d'/' -f1 | sed 's/^ *//;s/ *$//')"
  [ -n "$inner" ] || inner="$(printf '%s' "$line" | sed 's/^[^:]*: //; s/ (rev.*//')"
  local prefix=""
  case "$vendor" in
    amd) prefix="AMD " ;;
    intel) prefix="Intel " ;;
  esac
  case "$inner" in
    AMD*|NVIDIA*|Intel*) prefix="" ;;
  esac
  printf '%s%s' "$prefix" "$inner" | head -c 60
}

gpu_info() {
  local usage="null" temp="null" fan="null" vendor="none" name="" short="" pci_line=""
  pci_line="$(lspci 2>/dev/null | grep -i -m1 'vga\|3d controller')"

  # --- NVIDIA ---
  if command -v nvidia-smi >/dev/null 2>&1; then
    local out
    if out="$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,fan.speed,name --format=csv,noheader,nounits 2>/dev/null | head -n 1)" \
      && [ -n "$out" ] \
      && echo "$out" | grep -qE '^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*,[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*,'; then
      vendor="nvidia"
      usage="$(echo "$out" | cut -d',' -f1 | tr -dc '0-9.')"
      temp="$(echo "$out" | cut -d',' -f2 | tr -dc '0-9.')"
      fan="$(echo "$out" | cut -d',' -f3 | tr -dc '0-9.')"
      name="$(echo "$out" | cut -d',' -f4- | sed 's/^ //')"
      short="$name"
      [ -z "$usage" ] && usage="null"
      [ -z "$temp" ] && temp="null"
      [ -z "$fan" ] && fan="null"
    fi
  fi

  # --- AMD (sysfs) ---
  if [ "$vendor" = "none" ]; then
    local busy=""
    for c in /sys/class/drm/card*/device/gpu_busy_percent; do
      [ -f "$c" ] || continue
      # skip virtual/link devices without hwmon sibling
      busy="$(cat "$c" 2>/dev/null | tr -dc '0-9')"
      if [ -n "$busy" ]; then
        vendor="amd"
        usage="$busy"
        # temp: edge sensor of amdgpu hwmon
        for h in /sys/class/hwmon/hwmon*; do
          [ -f "$h/name" ] || continue
          [ "$(cat "$h/name" 2>/dev/null)" = "amdgpu" ] || continue
          for l in "$h"/temp*_label; do
            [ -f "$l" ] || continue
            if grep -qi "edge" "$l" 2>/dev/null; then
              local f="${l%_label}_input"
              if [ -f "$f" ]; then
                local raw
                raw="$(cat "$f" 2>/dev/null)"
                temp="$(awk -v v="$raw" 'BEGIN{printf "%.1f", v/1000}')"
                break
              fi
            fi
          done
          if [ "$temp" != "null" ]; then break; fi
          # fallback: first temp input of amdgpu
          if [ -f "$h/temp1_input" ]; then
            temp="$(awk -v v="$(cat "$h/temp1_input" 2>/dev/null)" 'BEGIN{printf "%.1f", v/1000}')"
            break
          fi
        done
        name="$(printf '%s' "$pci_line" | sed 's/.*: //')"
        short="$(gpu_short_from_lspci "$pci_line" "amd")"
        break
      fi
    done
  fi

  # --- Intel iGPU (sysfs busy via engine stats is complex; temp via coretemp PCH) ---
  if [ "$vendor" = "none" ]; then
    for h in /sys/class/hwmon/hwmon*; do
      [ -f "$h/name" ] || continue
      [ "$(cat "$h/name" 2>/dev/null)" = "i915" ] || continue
      vendor="intel"
      name="$(printf '%s' "$pci_line" | sed 's/.*: //')"
      short="$(gpu_short_from_lspci "$pci_line" "intel")"
      break
    done
    if [ "$vendor" = "intel" ] && command -v intel_gpu_top >/dev/null 2>&1; then
      local line
      line="$(timeout 2 intel_gpu_top -J -s 500 2>/dev/null | grep -o '"Render/3D/0":{[^}]*}' | head -n 1 | grep -o '"busy":[0-9.]*' | cut -d: -f2)"
      [ -n "$line" ] && usage="$line"
    fi
  fi

  # JSON-escape the names (strip quotes/backslashes)
  name="$(printf '%s' "$name" | tr -d '"\\' | head -c 80)"
  short="$(printf '%s' "$short" | tr -d '"\\' | head -c 60)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$usage" "$temp" "$fan" "$vendor" "$name" "$short"
}

CPU="$(cpu_usage)"
CTEMP="$(cpu_temp)"
read -r MEM_PCT MEM_USED MEM_TOTAL <<< "$(mem_info)"
IFS=$'\t' read -r GPU GPU_TEMP GPU_FAN GPU_VENDOR GPU_NAME GPU_SHORT <<< "$(gpu_info)"
IFS=$'\t' read -r CPU_FAN CPU_FAN_DUTY <<< "$(cpu_fan)"
IFS=$'\t' read -r CPU_MODEL CPU_THREADS CPU_MAXGHZ <<< "$(cpu_meta)"

# numbers or null must be emitted raw; strings quoted
[ "$CPU" = "null" ] || CPU="$CPU"
[ "$CTEMP" = "null" ] || CTEMP="$CTEMP"
[ "$MEM_PCT" = "null" ] || MEM_PCT="$MEM_PCT"
[ "$GPU" = "null" ] || GPU="$GPU"
[ "$GPU_TEMP" = "null" ] || GPU_TEMP="$GPU_TEMP"
[ "$MEM_USED" = "null" ] && MEM_USED="null" || MEM_USED="$MEM_USED"
[ "$MEM_TOTAL" = "null" ] && MEM_TOTAL="null" || MEM_TOTAL="$MEM_TOTAL"
[ "$CPU_THREADS" = "null" ] || CPU_THREADS="$CPU_THREADS"
[ "$CPU_MAXGHZ" = "null" ] || CPU_MAXGHZ="$CPU_MAXGHZ"

printf '{"cpu":%s,"cpu_temp":%s,"gpu":%s,"gpu_temp":%s,"gpu_fan":%s,"gpu_vendor":"%s","gpu_name":"%s","gpu_short":"%s","cpu_model":"%s","cpu_threads":%s,"cpu_max_ghz":%s,"mem":%s,"mem_used_kb":%s,"mem_total_kb":%s,"cpu_fan_rpm":%s,"cpu_fan_duty":%s}\n' \
  "$CPU" "$CTEMP" "$GPU" "$GPU_TEMP" "$GPU_FAN" "$GPU_VENDOR" "$GPU_NAME" "$GPU_SHORT" "$CPU_MODEL" "$CPU_THREADS" "$CPU_MAXGHZ" "$MEM_PCT" "$MEM_USED" "$MEM_TOTAL" "$CPU_FAN" "$CPU_FAN_DUTY"

// wartafak.sysmon data helpers - pure JS, Node-testable.
var HISTORY_LIMIT = 300; // 2s samples x 300 = 10 minutes

function numOrNull(v) {
  if (v === null || v === undefined || v === "") return null;
  var n = Number(v);
  if (!isFinite(n) || n < 0) return null;
  return n;
}

function parseStats(raw) {
  var fallback = {
    cpu: null, cpuTemp: null,
    gpu: null, gpuTemp: null, gpuVendor: "none", gpuName: "", gpuShort: "",
    cpuModel: "", cpuThreads: null, cpuMaxGhz: null,
    mem: null, memUsedKb: null, memTotalKb: null,
    cpuFanRpm: null, cpuFanDuty: null, gpuFan: null
  };
  var parsed;
  try {
    parsed = JSON.parse(String(raw || ""));
  } catch (e) {
    return fallback;
  }
  if (!parsed || typeof parsed !== "object") return fallback;
  var threads = parsed.cpu_threads === null || parsed.cpu_threads === undefined
    ? null : parseInt(parsed.cpu_threads, 10);
  if (!isFinite(threads) || threads <= 0) threads = null;
  return {
    cpu: numOrNull(parsed.cpu),
    cpuTemp: numOrNull(parsed.cpu_temp),
    gpu: numOrNull(parsed.gpu),
    gpuTemp: numOrNull(parsed.gpu_temp),
    gpuVendor: typeof parsed.gpu_vendor === "string" ? parsed.gpu_vendor : "none",
    gpuName: typeof parsed.gpu_name === "string" ? parsed.gpu_name : "",
    gpuShort: typeof parsed.gpu_short === "string" ? parsed.gpu_short : "",
    cpuModel: typeof parsed.cpu_model === "string" ? parsed.cpu_model : "",
    cpuThreads: threads,
    cpuMaxGhz: numOrNull(parsed.cpu_max_ghz),
    mem: numOrNull(parsed.mem),
    memUsedKb: numOrNull(parsed.mem_used_kb),
    memTotalKb: numOrNull(parsed.mem_total_kb),
    cpuFanRpm: numOrNull(parsed.cpu_fan_rpm),
    cpuFanDuty: numOrNull(parsed.cpu_fan_duty),
    gpuFan: numOrNull(parsed.gpu_fan)
  };
}

// Push value onto history array, capped at limit. Nulls are kept so gaps
// render as gaps instead of shifting the time axis.
function pushHistory(history, value, limit) {
  var list = Array.isArray(history) ? history.slice() : [];
  list.push(value === undefined ? null : value);
  var max = Math.max(1, parseInt(limit, 10) || HISTORY_LIMIT);
  while (list.length > max) list.shift();
  return list;
}

function average(history) {
  var list = Array.isArray(history) ? history : [];
  var total = 0, count = 0;
  for (var i = 0; i < list.length; i++) {
    var v = list[i];
    if (typeof v !== "number" || !isFinite(v)) continue;
    total += v;
    count++;
  }
  if (count === 0) return null;
  return total / count;
}

function fmtPct(v) {
  if (typeof v !== "number" || !isFinite(v)) return "--";
  return v.toFixed(v < 10 ? 1 : 0) + "%";
}

function fmtTemp(v) {
  if (typeof v !== "number" || !isFinite(v)) return "--";
  return v.toFixed(0) + "°";
}

function fmtMemDetail(usedKb, totalKb) {
  if (usedKb === null || usedKb === undefined || usedKb === ""
    || totalKb === null || totalKb === undefined || totalKb === "") return "";
  var u = Number(usedKb), t = Number(totalKb);
  if (!isFinite(u) || !isFinite(t) || t <= 0) return "";
  return (u / 1048576).toFixed(1) + " / " + (t / 1048576).toFixed(1) + " GB";
}

// "Intel(R) Core(TM) i5-10400F CPU @ 2.90GHz" + 12 + 4.3
// -> "Intel Core i5-10400F (12) @ 4.30 GHz"
function shortCpuName(model, threads, maxGhz) {
  var name = String(model || "").replace(/\(R\)|\(TM\)/g, "").replace(/\s+/g, " ").trim();
  // Drop the stock "CPU @ <base freq>" tail; we show max boost instead.
  name = name.replace(/\s*CPU\s*@.*$/i, "").trim();
  if (name === "") return "";
  var suffix = "";
  var th = parseInt(threads, 10);
  if (isFinite(th) && th > 0) suffix += " (" + th + ")";
  var ghz = Number(maxGhz);
  if (isFinite(ghz) && ghz > 0) suffix += " @ " + ghz.toFixed(2) + " GHz";
  return name + suffix;
}

function cpuTitle(s) {
  var v = s || {};
  var label = shortCpuName(v.cpuModel, v.cpuThreads, v.cpuMaxGhz);
  return label !== "" ? "CPU · " + label : "CPU";
}

function gpuTitle(s) {
  var v = s || {};
  var label = String(v.gpuShort || "").trim();
  return label !== "" ? "GPU · " + label : "GPU";
}

// Brand/model/freq need root (dmidecode); all we can read is total size.
function memTitle(s) {
  var v = s || {};
  var t = Number(v.memTotalKb);
  if (isFinite(t) && t > 0) return "MEMORY · " + (t / 1048576).toFixed(1) + " GiB";
  return "MEMORY";
}

// One row of processes.sh output. Null when the row is unusable (bad pid,
// empty name) so a corrupt line can't poison the table.
function parseProcess(o) {
  if (!o || typeof o !== "object") return null;
  var pid = parseInt(o.pid, 10);
  if (!isFinite(pid) || pid <= 0) return null;
  var comm = typeof o.comm === "string" ? o.comm : "";
  if (comm === "") return null;
  return { pid: pid, comm: comm.slice(0, 40), cpu: numOrNull(o.cpu), mem: numOrNull(o.mem), rssKb: numOrNull(o.rss_kb) };
}

function parseProcesses(raw) {
  var arr;
  try {
    arr = JSON.parse(String(raw || ""));
  } catch (e) {
    return [];
  }
  if (!Array.isArray(arr)) return [];
  var out = [];
  for (var i = 0; i < arr.length; i++) {
    var p = parseProcess(arr[i]);
    if (p) out.push(p);
  }
  return out;
}

// Table ordering. key is "cpu", "mem", "comm" or "pid"; dir is 1 (asc) or
// -1 (desc), anything else means desc. "mem" compares the absolute RSS
// (same order as mem% — one shared MemTotal — but exact, not rounded).
// Nulls always sort last, ties break by pid so the order is
// deterministic. Never mutates the input.
function sortProcesses(list, key, dir) {
  var arr = Array.isArray(list) ? list.slice() : [];
  var k = key === "mem" ? "mem" : key === "comm" ? "comm" : key === "pid" ? "pid" : "cpu";
  var d = dir === 1 ? 1 : -1;
  function val(p) {
    if (k === "mem" && p.rssKb !== null && p.rssKb !== undefined) return p.rssKb;
    return p[k];
  }
  arr.sort(function (a, b) {
    var av = val(a), bv = val(b);
    var an = av === null || av === undefined;
    var bn = bv === null || bv === undefined;
    if (an && bn) return a.pid - b.pid;
    if (an) return 1;
    if (bn) return -1;
    var cmp;
    if (k === "comm") {
      var as = String(av), bs = String(bv);
      cmp = as < bs ? -1 : as > bs ? 1 : 0;
    } else {
      cmp = av < bv ? -1 : av > bv ? 1 : 0;
    }
    if (cmp !== 0) return cmp * d;
    return a.pid - b.pid;
  });
  return arr;
}

// Process table filter: case-insensitive name substring or PID prefix.
// Blank query keeps everything. Never mutates the input.
function filterProcesses(list, query) {
  var arr = Array.isArray(list) ? list : [];
  var q = String(query || "").trim().toLowerCase();
  if (q === "") return arr.slice();
  return arr.filter(function (p) {
    return String(p.comm || "").toLowerCase().indexOf(q) >= 0 || String(p.pid).indexOf(q) === 0;
  });
}

// "1.3GB (3.6%)" — absolute RSS plus percent for the process table.
// GB with one decimal at >= 1 GiB, whole MB below. "--" when unknown;
// partial info still renders ("1.3GB" / "(3.6%)").
function fmtProcMem(p) {
  var v = p || {};
  var rss = numOrNull(v.rssKb), pct = numOrNull(v.mem);
  if (rss === null && pct === null) return "--";
  var abs = "";
  if (rss !== null) {
    abs = rss >= 1048576 ? (rss / 1048576).toFixed(1) + "GB" : Math.round(rss / 1024) + "MB";
  }
  if (pct === null) return abs;
  var ps = pct.toFixed(1) + "%";
  return abs !== "" ? abs + " (" + ps + ")" : "(" + ps + ")";
}

function fmtRpm(v) {
  if (typeof v !== "number" || !isFinite(v)) return "--";
  return Math.round(v) + " RPM";
}

// Fans can't report why they spin, so name what each one reacts to: the
// CPU fan follows CPU temp (board fan curve), the GPU fan its own GPU.
// topProc is the busiest process ({comm, cpu}) or null.
function cpuFanDriver(s, topProc) {
  var v = s || {};
  var parts = ["CPU " + fmtTemp(v.cpuTemp) + " · " + fmtPct(v.cpu) + " load"];
  if (topProc && topProc.comm && typeof topProc.cpu === "number" && topProc.cpu >= 1)
    parts.push("top: " + topProc.comm + " " + fmtPct(topProc.cpu));
  return parts.join(" · ");
}

function gpuFanDriver(s) {
  var v = s || {};
  return "GPU " + fmtTemp(v.gpuTemp) + " · " + fmtPct(v.gpu) + " load";
}

// Which fan works hardest right now, as % of its range: "cpu", "gpu" or
// "" when no fan reading exists. GPU wins only when strictly busier.
function loudestFan(s) {
  var v = s || {};
  var c = typeof v.cpuFanDuty === "number" ? v.cpuFanDuty : null;
  var g = typeof v.gpuFan === "number" ? v.gpuFan : null;
  if (c === null && g === null) return "";
  if (c === null) return "gpu";
  if (g === null) return "cpu";
  return g > c ? "gpu" : "cpu";
}

// Map a value in [min,max] to a Y pixel in [0,height] (0 = top).
function yFor(value, min, max, height) {
  var lo = Number(min), hi = Number(max), h = Number(height);
  if (!isFinite(lo) || !isFinite(hi) || hi <= lo) return h;
  if (typeof value !== "number" || !isFinite(value)) return NaN;
  var clamped = Math.max(lo, Math.min(hi, value));
  return h - ((clamped - lo) / (hi - lo)) * h;
}

// X pixel for sample index i of count points in width.
function xFor(i, count, width) {
  var n = Math.max(1, parseInt(count, 10) || 1);
  var w = Number(width);
  if (n <= 1) return w;
  return (i / (n - 1)) * w;
}

if (typeof module !== "undefined") {
  module.exports = {
    HISTORY_LIMIT: HISTORY_LIMIT,
    numOrNull: numOrNull,
    parseStats: parseStats,
    pushHistory: pushHistory,
    average: average,
    fmtPct: fmtPct,
    fmtTemp: fmtTemp,
    fmtMemDetail: fmtMemDetail,
    fmtRpm: fmtRpm,
    cpuFanDriver: cpuFanDriver,
    gpuFanDriver: gpuFanDriver,
    loudestFan: loudestFan,
    shortCpuName: shortCpuName,
    cpuTitle: cpuTitle,
    gpuTitle: gpuTitle,
    memTitle: memTitle,
    parseProcess: parseProcess,
    parseProcesses: parseProcesses,
    sortProcesses: sortProcesses,
    filterProcesses: filterProcesses,
    fmtProcMem: fmtProcMem,
    yFor: yFor,
    xFor: xFor
  };
}

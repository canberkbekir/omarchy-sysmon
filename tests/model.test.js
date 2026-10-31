// Unit tests for Model.js — run with:  node --test tests/
// No dependencies (uses only node:test + node:assert).

const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

describe("HISTORY_LIMIT", () => {
  it("covers 10 minutes of 2s samples", () => {
    assert.equal(M.HISTORY_LIMIT, 300)
  })
})

describe("numOrNull", () => {
  it("passes numbers through", () => {
    assert.equal(M.numOrNull(0), 0)
    assert.equal(M.numOrNull(42.5), 42.5)
    assert.equal(M.numOrNull("12.3"), 12.3)
  })
  it("nulls blanks and missing values", () => {
    assert.equal(M.numOrNull(null), null)
    assert.equal(M.numOrNull(undefined), null)
    assert.equal(M.numOrNull(""), null)
  })
  it("nulls negatives and non-finite values", () => {
    assert.equal(M.numOrNull(-1), null)
    assert.equal(M.numOrNull(NaN), null)
    assert.equal(M.numOrNull(Infinity), null)
    assert.equal(M.numOrNull("nope"), null)
  })
})

describe("parseStats", () => {
  const full = JSON.stringify({
    cpu: 12.5, cpu_temp: 55.0,
    gpu: 33.0, gpu_temp: 60.0, gpu_vendor: "amd",
    gpu_name: "AMD Radeon", gpu_short: "AMD Radeon RX 6650 XT",
    cpu_model: "Intel(R) Core(TM) i5-10400F CPU @ 2.90GHz",
    cpu_threads: 12, cpu_max_ghz: 4.3,
    mem: 27.1, mem_used_kb: 4414380, mem_total_kb: 16302004
  })
  it("parses a full stats.sh payload", () => {
    const s = M.parseStats(full)
    assert.equal(s.cpu, 12.5)
    assert.equal(s.cpuTemp, 55.0)
    assert.equal(s.gpu, 33.0)
    assert.equal(s.gpuTemp, 60.0)
    assert.equal(s.gpuVendor, "amd")
    assert.equal(s.gpuShort, "AMD Radeon RX 6650 XT")
    assert.equal(s.cpuThreads, 12)
    assert.equal(s.cpuMaxGhz, 4.3)
    assert.equal(s.mem, 27.1)
    assert.equal(s.memUsedKb, 4414380)
    assert.equal(s.memTotalKb, 16302004)
  })
  it("keeps nulls from stats.sh as null", () => {
    const s = M.parseStats('{"cpu":null,"cpu_temp":null,"gpu":null,"gpu_temp":null,"gpu_vendor":"none","gpu_name":"","gpu_short":"","cpu_model":"","cpu_threads":null,"cpu_max_ghz":null,"mem":null,"mem_used_kb":null,"mem_total_kb":null}')
    assert.equal(s.cpu, null)
    assert.equal(s.gpuVendor, "none")
    assert.equal(s.cpuThreads, null)
  })
  it("falls back on invalid JSON", () => {
    const s = M.parseStats("not json")
    assert.equal(s.cpu, null)
    assert.equal(s.gpuVendor, "none")
    assert.equal(s.mem, null)
  })
  it("falls back on empty / missing input", () => {
    for (const raw of ["", null, undefined]) {
      const s = M.parseStats(raw)
      assert.equal(s.cpu, null)
      assert.equal(s.gpuVendor, "none")
    }
  })
  it("falls back on non-object JSON", () => {
    assert.equal(M.parseStats("[1,2]").cpu, null)
    assert.equal(M.parseStats("42").cpu, null)
  })
  it("rejects negative and non-numeric readings", () => {
    const s = M.parseStats('{"cpu":-5,"cpu_temp":"hot","mem":"-1"}')
    assert.equal(s.cpu, null)
    assert.equal(s.cpuTemp, null)
    assert.equal(s.mem, null)
  })
  it("rejects non-positive thread counts", () => {
    assert.equal(M.parseStats('{"cpu_threads":0}').cpuThreads, null)
    assert.equal(M.parseStats('{"cpu_threads":-4}').cpuThreads, null)
    assert.equal(M.parseStats('{"cpu_threads":"x"}').cpuThreads, null)
  })
})

describe("pushHistory", () => {
  it("appends values", () => {
    assert.deepEqual(M.pushHistory([1, 2], 3, 10), [1, 2, 3])
  })
  it("keeps nulls so gaps render as gaps", () => {
    assert.deepEqual(M.pushHistory([1], null, 10), [1, null])
    assert.deepEqual(M.pushHistory([], undefined, 10), [null])
  })
  it("caps at the limit", () => {
    assert.deepEqual(M.pushHistory([1, 2, 3], 4, 3), [2, 3, 4])
  })
  it("defaults to HISTORY_LIMIT for bad limits", () => {
    const out = M.pushHistory([], 1, 0)
    assert.equal(out.length, 1)
    const big = Array.from({ length: 310 }, (_, i) => i)
    assert.equal(M.pushHistory(big, 999).length, M.HISTORY_LIMIT)
  })
  it("starts from empty on non-arrays", () => {
    assert.deepEqual(M.pushHistory(null, 5, 10), [5])
    assert.deepEqual(M.pushHistory("x", 5, 10), [5])
  })
  it("does not mutate the input", () => {
    const src = [1, 2]
    M.pushHistory(src, 3, 10)
    assert.deepEqual(src, [1, 2])
  })
})

describe("average", () => {
  it("averages plain samples", () => {
    assert.equal(M.average([10, 20, 30]), 20)
  })
  it("skips gaps and non-numbers", () => {
    assert.equal(M.average([10, null, 20, undefined, "x", NaN]), 15)
  })
  it("returns null when there is nothing to average", () => {
    assert.equal(M.average([]), null)
    assert.equal(M.average([null, null]), null)
    assert.equal(M.average(null), null)
  })
})

describe("fmtPct", () => {
  it("uses one decimal below 10", () => {
    assert.equal(M.fmtPct(6.15), "6.2%")
  })
  it("uses no decimals at 10 and above", () => {
    assert.equal(M.fmtPct(27.1), "27%")
    assert.equal(M.fmtPct(100), "100%")
  })
  it("dashes missing values", () => {
    assert.equal(M.fmtPct(null), "--")
    assert.equal(M.fmtPct(undefined), "--")
    assert.equal(M.fmtPct(NaN), "--")
  })
})

describe("fmtTemp", () => {
  it("rounds to whole degrees", () => {
    assert.equal(M.fmtTemp(35.6), "36°")
    assert.equal(M.fmtTemp(35.0), "35°")
  })
  it("dashes missing values", () => {
    assert.equal(M.fmtTemp(null), "--")
    assert.equal(M.fmtTemp("hot"), "--")
  })
})

describe("fmtMemDetail", () => {
  it("formats used/total GiB", () => {
    assert.equal(M.fmtMemDetail(4414380, 16302004), "4.2 / 15.5 GB")
  })
  it("blanks when total is missing", () => {
    assert.equal(M.fmtMemDetail(100, 0), "")
    assert.equal(M.fmtMemDetail(100, null), "")
    assert.equal(M.fmtMemDetail(null, 16302004), "")
  })
})

describe("shortCpuName", () => {
  it("shortens a full Intel model string", () => {
    assert.equal(
      M.shortCpuName("Intel(R) Core(TM) i5-10400F CPU @ 2.90GHz", 12, 4.3),
      "Intel Core i5-10400F (12) @ 4.30 GHz"
    )
  })
  it("omits missing parts", () => {
    assert.equal(M.shortCpuName("AMD Ryzen 5", null, null), "AMD Ryzen 5")
    assert.equal(M.shortCpuName("AMD Ryzen 5", 12, null), "AMD Ryzen 5 (12)")
  })
  it("blanks on empty model", () => {
    assert.equal(M.shortCpuName("", 12, 4.3), "")
    assert.equal(M.shortCpuName(null, null, null), "")
  })
})

describe("titles", () => {
  it("cpuTitle prefixes the short name", () => {
    assert.equal(
      M.cpuTitle({ cpuModel: "Intel(R) Core(TM) i5-10400F CPU @ 2.90GHz", cpuThreads: 12, cpuMaxGhz: 4.3 }),
      "CPU · Intel Core i5-10400F (12) @ 4.30 GHz"
    )
    assert.equal(M.cpuTitle({}), "CPU")
    assert.equal(M.cpuTitle(null), "CPU")
  })
  it("gpuTitle prefixes the short name", () => {
    assert.equal(M.gpuTitle({ gpuShort: "AMD Radeon RX 6650 XT" }), "GPU · AMD Radeon RX 6650 XT")
    assert.equal(M.gpuTitle({ gpuShort: "" }), "GPU")
    assert.equal(M.gpuTitle(null), "GPU")
  })
  it("memTitle shows total GiB when known", () => {
    assert.equal(M.memTitle({ memTotalKb: 16302004 }), "MEMORY · 15.5 GiB")
    assert.equal(M.memTitle({}), "MEMORY")
    assert.equal(M.memTitle(null), "MEMORY")
  })
})

describe("yFor", () => {
  it("maps min to bottom and max to top", () => {
    assert.equal(M.yFor(0, 0, 100, 100), 100)
    assert.equal(M.yFor(100, 0, 100, 100), 0)
    assert.equal(M.yFor(50, 0, 100, 100), 50)
  })
  it("clamps out-of-range values", () => {
    assert.equal(M.yFor(-10, 0, 100, 100), 100)
    assert.equal(M.yFor(150, 0, 100, 100), 0)
  })
  it("yields NaN for gaps and height for bad scales", () => {
    assert.ok(Number.isNaN(M.yFor(null, 0, 100, 100)))
    assert.equal(M.yFor(50, 100, 100, 100), 100)
  })
})

describe("xFor", () => {
  it("stretches first..last across the width", () => {
    assert.equal(M.xFor(0, 4, 300), 0)
    assert.equal(M.xFor(3, 4, 300), 300)
    assert.equal(M.xFor(1, 3, 200), 100)
  })
  it("parks single samples on the right", () => {
    assert.equal(M.xFor(0, 1, 300), 300)
  })
})

describe("parseProcesses", () => {
  it("parses processes.sh output", () => {
    const list = M.parseProcesses('[{"pid":1,"comm":"systemd","cpu":0.3,"mem":0.1,"rss_kb":1234},{"pid":42,"comm":"foot","cpu":12.5,"mem":1.2,"rss_kb":567890}]')
    assert.deepEqual(list, [
      { pid: 1, comm: "systemd", cpu: 0.3, mem: 0.1, rssKb: 1234 },
      { pid: 42, comm: "foot", cpu: 12.5, mem: 1.2, rssKb: 567890 }
    ])
  })
  it("drops corrupt rows but keeps the rest", () => {
    const list = M.parseProcesses('[{"pid":1,"comm":"ok","cpu":1,"mem":1,"rss_kb":10},{"pid":0,"comm":"x","cpu":1,"mem":1},{"pid":2,"comm":"","cpu":1,"mem":1},"nope",null]')
    assert.deepEqual(list, [{ pid: 1, comm: "ok", cpu: 1, mem: 1, rssKb: 10 }])
  })
  it("keeps null readings as null", () => {
    assert.deepEqual(
      M.parseProcesses('[{"pid":7,"comm":"kworker","cpu":null,"mem":null}]'),
      [{ pid: 7, comm: "kworker", cpu: null, mem: null, rssKb: null }]
    )
  })
  it("returns [] for invalid input", () => {
    for (const raw of ["not json", "", null, undefined, '{"pid":1}', "42"]) {
      assert.deepEqual(M.parseProcesses(raw), [])
    }
  })
  it("truncates overlong names", () => {
    const list = M.parseProcesses(JSON.stringify([{ pid: 1, comm: "x".repeat(100), cpu: 0, mem: 0 }]))
    assert.equal(list[0].comm.length, 40)
  })
})

describe("sortProcesses", () => {
  const rows = [
    { pid: 3, comm: "zed", cpu: 0.0, mem: 2.3 },
    { pid: 1, comm: "systemd", cpu: 0.3, mem: 0.1 },
    { pid: 2, comm: "foot", cpu: 12.5, mem: 1.2 }
  ]
  it("sorts by cpu descending by default", () => {
    assert.deepEqual(M.sortProcesses(rows).map((p) => p.pid), [2, 1, 3])
    assert.deepEqual(M.sortProcesses(rows, "cpu", -1).map((p) => p.pid), [2, 1, 3])
  })
  it("sorts ascending on dir 1", () => {
    assert.deepEqual(M.sortProcesses(rows, "cpu", 1).map((p) => p.pid), [3, 1, 2])
  })
  it("sorts by mem and by name", () => {
    assert.deepEqual(M.sortProcesses(rows, "mem", -1).map((p) => p.pid), [3, 2, 1])
    assert.deepEqual(M.sortProcesses(rows, "comm", 1).map((p) => p.pid), [2, 1, 3])
  })
  it("sorts by pid", () => {
    assert.deepEqual(M.sortProcesses(rows, "pid", 1).map((p) => p.pid), [1, 2, 3])
    assert.deepEqual(M.sortProcesses(rows, "pid", -1).map((p) => p.pid), [3, 2, 1])
  })
  it("falls back to cpu on unknown keys", () => {
    assert.deepEqual(M.sortProcesses(rows, "gpu", -1).map((p) => p.pid), [2, 1, 3])
  })
  it("sorts by mem on absolute RSS, not the rounded percent", () => {
    const mixed = [
      { pid: 1, comm: "a", cpu: 0, mem: 5.0, rssKb: 100000 },
      { pid: 2, comm: "b", cpu: 0, mem: 1.0, rssKb: 900000 }
    ]
    assert.deepEqual(M.sortProcesses(mixed, "mem", -1).map((p) => p.pid), [2, 1])
  })
  it("falls back to mem percent without rssKb", () => {
    const legacy = [
      { pid: 1, comm: "a", cpu: 0, mem: 1.0 },
      { pid: 2, comm: "b", cpu: 0, mem: 5.0 }
    ]
    assert.deepEqual(M.sortProcesses(legacy, "mem", -1).map((p) => p.pid), [2, 1])
  })
  it("parks nulls last either way and breaks ties by pid", () => {
    const withNull = rows.concat([{ pid: 9, comm: "kworker", cpu: null, mem: null }])
    assert.deepEqual(M.sortProcesses(withNull, "cpu", -1).map((p) => p.pid), [2, 1, 3, 9])
    assert.deepEqual(M.sortProcesses(withNull, "cpu", 1).map((p) => p.pid), [3, 1, 2, 9])
    const tied = [
      { pid: 5, comm: "a", cpu: 1.0, mem: 0 },
      { pid: 4, comm: "b", cpu: 1.0, mem: 0 }
    ]
    assert.deepEqual(M.sortProcesses(tied, "cpu", -1).map((p) => p.pid), [4, 5])
  })
  it("does not mutate the input", () => {
    const src = rows.map((p) => ({ ...p }))
    M.sortProcesses(src, "cpu", -1)
    assert.deepEqual(src.map((p) => p.pid), [3, 1, 2])
  })
  it("handles non-arrays", () => {
    assert.deepEqual(M.sortProcesses(null, "cpu", -1), [])
  })
})

describe("fmtProcMem", () => {
  it("formats GB with percent", () => {
    assert.equal(M.fmtProcMem({ rssKb: 1363148, mem: 3.6 }), "1.3GB (3.6%)")
  })
  it("formats whole MB below 1 GiB", () => {
    assert.equal(M.fmtProcMem({ rssKb: 239616, mem: 1.4 }), "234MB (1.4%)")
  })
  it("renders partial info", () => {
    assert.equal(M.fmtProcMem({ rssKb: 1363148, mem: null }), "1.3GB")
    assert.equal(M.fmtProcMem({ rssKb: null, mem: 3.6 }), "(3.6%)")
  })
  it("dashes fully unknown values", () => {
    assert.equal(M.fmtProcMem({ rssKb: null, mem: null }), "--")
    assert.equal(M.fmtProcMem({}), "--")
    assert.equal(M.fmtProcMem(null), "--")
  })
})

describe("fans", () => {
  it("parseStats reads fan fields and nulls them when absent", () => {
    const s = M.parseStats(JSON.stringify({ cpu_fan_rpm: 1574, cpu_fan_duty: 76, gpu_fan: 30 }))
    assert.equal(s.cpuFanRpm, 1574)
    assert.equal(s.cpuFanDuty, 76)
    assert.equal(s.gpuFan, 30)
    const e = M.parseStats("{}")
    assert.equal(e.cpuFanRpm, null)
    assert.equal(e.gpuFan, null)
    assert.equal(M.parseStats("garbage").cpuFanDuty, null)
  })
  it("fmtRpm", () => {
    assert.equal(M.fmtRpm(1573.6), "1574 RPM")
    assert.equal(M.fmtRpm(null), "--")
  })
  it("cpuFanDriver names temp, load and busiest process", () => {
    const s = { cpuTemp: 73, cpu: 45 }
    assert.equal(M.cpuFanDriver(s, { comm: "cargo", cpu: 30 }), "CPU 73° · 45% load · top: cargo 30%")
    assert.equal(M.cpuFanDriver(s, { comm: "idle", cpu: 0.2 }), "CPU 73° · 45% load")
    assert.equal(M.cpuFanDriver(s, null), "CPU 73° · 45% load")
  })
  it("gpuFanDriver", () => {
    assert.equal(M.gpuFanDriver({ gpuTemp: 60, gpu: 80 }), "GPU 60° · 80% load")
  })
  it("loudestFan", () => {
    assert.equal(M.loudestFan({}), "")
    assert.equal(M.loudestFan({ cpuFanDuty: 50, gpuFan: null }), "cpu")
    assert.equal(M.loudestFan({ cpuFanDuty: null, gpuFan: 20 }), "gpu")
    assert.equal(M.loudestFan({ cpuFanDuty: 50, gpuFan: 50 }), "cpu")
    assert.equal(M.loudestFan({ cpuFanDuty: 40, gpuFan: 60 }), "gpu")
  })
})

describe("filterProcesses", () => {
  const list = [
    { pid: 1377, comm: "Hyprland" },
    { pid: 21331, comm: "claude" },
    { pid: 13, comm: "kworker" }
  ]
  it("keeps everything for a blank query", () => {
    assert.equal(M.filterProcesses(list, "  ").length, 3)
    assert.notEqual(M.filterProcesses(list, ""), list)
  })
  it("matches names case-insensitively", () => {
    assert.deepEqual(M.filterProcesses(list, "hypr").map(p => p.pid), [1377])
  })
  it("matches pid prefixes, not substrings", () => {
    assert.deepEqual(M.filterProcesses(list, "13").map(p => p.pid), [1377, 13])
    assert.deepEqual(M.filterProcesses(list, "33").map(p => p.pid), [])
  })
  it("tolerates junk", () => {
    assert.deepEqual(M.filterProcesses(null, "x"), [])
  })
})

describe("time ranges", () => {
  it("RANGES are 10s, 1m, 5m, 10m", () => {
    assert.deepEqual(M.RANGES, [10, 60, 300, 600])
  })
  it("windowSamples converts seconds to 2s samples, clamped", () => {
    assert.equal(M.windowSamples(10, 2), 5)
    assert.equal(M.windowSamples(60, 2), 30)
    assert.equal(M.windowSamples(600, 2), 300)
    assert.equal(M.windowSamples(3600, 2), 300)
    assert.equal(M.windowSamples(1, 2), 2)
    assert.equal(M.windowSamples(null, 2), 300)
  })
  it("lastWindow keeps the newest n", () => {
    assert.deepEqual(M.lastWindow([1, 2, 3, 4, 5], 2), [4, 5])
    assert.deepEqual(M.lastWindow([1, 2], 5), [1, 2])
    assert.deepEqual(M.lastWindow(null, 3), [])
  })
  it("fmtRange", () => {
    assert.equal(M.fmtRange(10), "10S")
    assert.equal(M.fmtRange(60), "1M")
    assert.equal(M.fmtRange(300), "5M")
    assert.equal(M.fmtRange(90), "90S")
  })
})

describe("storage", () => {
  const raw = JSON.stringify([
    { mount: "/boot", fstype: "vfat", encrypted: false, size: 2143281152, used: 579936256, avail: 1563344896, pct: 28, shared: [] },
    { mount: "/", fstype: "btrfs", encrypted: true, size: 1998232485888, used: 248842874880, avail: 1747522605056, pct: 13, shared: ["/home"] },
    { mount: "", size: 10 },
    null
  ])

  it("parses volumes and drops unusable rows", () => {
    assert.equal(M.parseVolumes(raw).length, 2)
    assert.deepEqual(M.parseVolumes("garbage"), [])
    assert.deepEqual(M.parseVolumes(""), [])
  })
  it("prefers / as the primary volume", () => {
    assert.equal(M.primaryVolume(M.parseVolumes(raw)).mount, "/")
    assert.equal(M.primaryVolume([{ mount: "/data" }]).mount, "/data")
    assert.equal(M.primaryVolume([]), null)
  })
  it("formats bytes in df-style binary units", () => {
    assert.equal(M.fmtBytes(1747522605056), "1.6 TB")
    assert.equal(M.fmtBytes(248842874880), "232 GB")
    assert.equal(M.fmtBytes(4778151936), "4.5 GB")
    assert.equal(M.fmtBytes(579936256), "553 MB")
    assert.equal(M.fmtBytes(null), "--")
  })
  it("maps usage to warning levels at 80 and 90", () => {
    assert.equal(M.storageLevel(13), "normal")
    assert.equal(M.storageLevel(80), "warning")
    assert.equal(M.storageLevel(90), "critical")
    assert.equal(M.storageLevel(null), "")
  })
  it("builds the bar readout, marking a critical disk", () => {
    const root = M.primaryVolume(M.parseVolumes(raw))
    assert.equal(M.fmtBarUsed(root), "13%")
    assert.equal(M.fmtBarUsed({ pct: 94 }), "94% !")
    assert.equal(M.fmtBarUsed(null), "--")
  })
  it("describes a volume", () => {
    const root = M.primaryVolume(M.parseVolumes(raw))
    assert.equal(M.fmtVolumeDetail(root), "232 GB / 1.8 TB · 1.6 TB free")
    assert.equal(M.fmtVolumeMeta(root), "btrfs · encrypted")
    assert.equal(M.fmtVolumeDetail(null), "not available")
  })
  it("parses scans, rejecting unusable output", () => {
    const scan = M.parseScan(JSON.stringify({ total: 30, folders: [{ name: "a", bytes: 20 }, { name: "", bytes: 10 }] }))
    assert.deepEqual(scan, { total: 30, folders: [{ name: "a", bytes: 20 }] })
    assert.equal(M.parseScan("garbage"), null)
    assert.equal(M.parseScan(JSON.stringify({ total: 0, folders: [] })), null)
  })
  it("clamps fractions", () => {
    assert.equal(M.fraction(25, 100), 0.25)
    assert.equal(M.fraction(200, 100), 1)
    assert.equal(M.fraction(5, 0), 0)
    assert.equal(M.fraction(null, 100), 0)
  })
})

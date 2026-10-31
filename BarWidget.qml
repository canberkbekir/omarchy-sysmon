import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// wartafak.sysmon bar widget: compact CPU/GPU/MEM readout.
// Owns the 2s poller and the 10-minute (300-sample) histories; the popup
// panel (Panel.qml) reads them through `hostWidget`.
BarWidget {
  id: root
  moduleName: "wartafak.sysmon"

  // ---- live values (null = unavailable) ----
  property var cpu: null
  property var cpuTemp: null
  property var gpu: null
  property var gpuTemp: null
  property string gpuVendor: "none"
  property string gpuName: ""
  property string gpuShort: ""
  property string cpuModel: ""
  property var cpuThreads: null
  property var cpuMaxGhz: null
  property var mem: null
  property var memUsedKb: null
  property var memTotalKb: null
  property var cpuFanRpm: null
  property var cpuFanDuty: null
  property var gpuFan: null

  // ---- 10-minute histories (2s x 300) ----
  property var cpuHist: []
  property var cpuTempHist: []
  property var gpuHist: []
  property var gpuTempHist: []
  property var memHist: []
  property var cpuFanHist: []
  property var gpuFanHist: []

  readonly property var cpuAvg: Model.average(cpuHist)
  readonly property var cpuTempAvg: Model.average(cpuTempHist)
  readonly property var gpuAvg: Model.average(gpuHist)
  readonly property var gpuTempAvg: Model.average(gpuTempHist)
  readonly property var memAvg: Model.average(memHist)
  readonly property var cpuFanAvg: Model.average(cpuFanHist)
  readonly property var gpuFanAvg: Model.average(gpuFanHist)
  readonly property bool hasCpuFan: cpuFanRpm !== null
  readonly property bool hasGpuFan: hasGpu && gpuFan !== null
  readonly property string loudestFan: Model.loudestFan({ cpuFanDuty: hasCpuFan ? cpuFanDuty : null, gpuFan: hasGpuFan ? gpuFan : null })
  // Busiest process from the last sample (list is sorted by cpu desc).
  readonly property var topProc: processes.length > 0 ? processes[0] : null
  readonly property int sampleCount: Math.max(cpuHist.length, memHist.length)
  readonly property bool hasGpu: gpuVendor !== "none"

  readonly property string helperPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/wartafak.sysmon/stats.sh"
  readonly property int pollMs: 2000

  // ---- process list (sampled only while the panel is open) ----
  property var processes: []
  readonly property int processCount: processes.length
  readonly property string procHelperPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/wartafak.sysmon/processes.sh"
  readonly property string killHelperPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/wartafak.sysmon/killproc.sh"
  readonly property int procPollMs: 2000
  // While the panel is closed, sample processes slowly so the tooltip can
  // still name what is heating the CPU.
  readonly property int procIdlePollMs: 10000

  // ---- storage ----
  // df reads filesystem counters, so the bar polls it cheaply. The folder
  // scan walks every file: it runs only when the Storage tab opens, and the
  // last result stays on screen until a new one arrives.
  property var volumes: []
  readonly property var primaryVolume: Model.primaryVolume(volumes)
  property var scanResult: null
  property bool scanFailed: false
  // Set only once a scan outlasts scanHintMs, so fast scans never flash.
  property bool scanSlow: false
  readonly property int storagePollMs: 60000
  readonly property int scanHintMs: 300
  readonly property string storageHelperPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/wartafak.sysmon/storage.sh"
  readonly property string scanHelperPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/wartafak.sysmon/scan.sh"

  // ---- theme palette (dynamic) ----
  // qs.Commons.Color only exposes foreground/background/accent/urgent/
  // muted, so read the active theme's full palette for the temp + memory
  // colors. Falls back to the previous hardcodes when a theme omits them.
  property color themeTemp: "#e0af68"
  property color themeGreen: "#9ece6a"
  property color themePurple: "#ad8ee6"
  property color themeCyan: "#449dab"

  function loadThemePalette(raw) {
    var yellow = "", orange = "", green = "", magenta = "", purple = "", cyan = ""
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*(yellow|orange|green|magenta|purple|cyan)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!m) continue
      if (m[1] === "yellow") yellow = m[2]
      else if (m[1] === "orange") orange = m[2]
      else if (m[1] === "green") green = m[2]
      else if (m[1] === "magenta") magenta = m[2]
      else if (m[1] === "purple") purple = m[2]
      else if (m[1] === "cyan") cyan = m[2]
    }
    // Yellow first: it preserves the established temp look on themes like
    // tokyo-night whose yellow is this orange-yellow.
    root.themeTemp = yellow || orange || "#e0af68"
    root.themeGreen = green || "#9ece6a"
    root.themePurple = magenta || purple || "#ad8ee6"
    root.themeCyan = cyan || "#449dab"
  }

  property FileView themeColorsFile: FileView {
    path: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadThemePalette(text())
    onFileChanged: reload()
    onLoadFailed: root.loadThemePalette("")
  }

  function refresh() {
    if (!statsProc.running) {
      statsProc.command = ["bash", helperPath]
      statsProc.running = true
    }
  }

  function refreshProcesses() {
    if (!procProc.running) {
      procProc.command = ["bash", procHelperPath]
      procProc.running = true
    }
  }

  function refreshStorage() {
    if (!storageProc.running) {
      storageProc.command = ["bash", storageHelperPath]
      storageProc.running = true
    }
  }

  function startScan() {
    if (scanProc.running) return
    root.scanFailed = false
    root.scanSlow = false
    scanHint.restart()
    scanProc.command = ["bash", scanHelperPath]
    scanProc.running = true
  }

  function applyScan(raw) {
    scanHint.stop()
    root.scanSlow = false
    var result = Model.parseScan(raw)
    if (result) root.scanResult = result
    root.scanFailed = !result
  }

  function applyProcesses(raw) {
    var list = Model.parseProcesses(raw)
    root.processes = list
  }

  // Signal a process by pid. force=false sends TERM, true sends KILL.
  // killproc.sh validates its args; pid 1 is never signalled.
  function killProcess(pid, force) {
    var id = parseInt(pid, 10)
    if (!isFinite(id) || id <= 1) return
    if (killProc.running) return
    killProc.command = ["bash", killHelperPath, force ? "KILL" : "TERM", String(id)]
    killProc.running = true
  }

  // Copy a pid to the clipboard (wl-copy takes the text as argv, so no
  // shell is involved). Fire-and-forget: wl-copy forks to serve pastes.
  function copyPid(pid) {
    var id = parseInt(pid, 10)
    if (!isFinite(id) || id <= 0) return
    if (copyProc.running) return
    copyProc.command = ["wl-copy", String(id)]
    copyProc.running = true
  }

  function applyStats(raw) {
    var s = Model.parseStats(raw)
    root.cpu = s.cpu
    root.cpuTemp = s.cpuTemp
    root.gpu = s.gpu
    root.gpuTemp = s.gpuTemp
    root.gpuVendor = s.gpuVendor
    root.gpuName = s.gpuName
    root.gpuShort = s.gpuShort
    root.cpuModel = s.cpuModel
    root.cpuThreads = s.cpuThreads
    root.cpuMaxGhz = s.cpuMaxGhz
    root.mem = s.mem
    root.memUsedKb = s.memUsedKb
    root.memTotalKb = s.memTotalKb
    root.cpuFanRpm = s.cpuFanRpm
    root.cpuFanDuty = s.cpuFanDuty
    root.gpuFan = s.gpuFan
    // Histories only advance on real samples so a failed poll leaves a
    // gap instead of fabricating a zero.
    root.cpuHist = Model.pushHistory(root.cpuHist, s.cpu, Model.HISTORY_LIMIT)
    root.cpuTempHist = Model.pushHistory(root.cpuTempHist, s.cpuTemp, Model.HISTORY_LIMIT)
    root.gpuHist = Model.pushHistory(root.gpuHist, s.gpu, Model.HISTORY_LIMIT)
    root.gpuTempHist = Model.pushHistory(root.gpuTempHist, s.gpuTemp, Model.HISTORY_LIMIT)
    root.memHist = Model.pushHistory(root.memHist, s.mem, Model.HISTORY_LIMIT)
    root.cpuFanHist = Model.pushHistory(root.cpuFanHist, s.cpuFanDuty, Model.HISTORY_LIMIT)
    root.gpuFanHist = Model.pushHistory(root.gpuFanHist, s.gpuFan, Model.HISTORY_LIMIT)
  }

  function barText() {
    if (root.vertical) return ""
    var parts = []
    parts.push(" " + Model.fmtPct(root.cpu) + " " + Model.fmtTemp(root.cpuTemp))
    if (root.hasGpu)
      parts.push(" " + Model.fmtPct(root.gpu) + " " + Model.fmtTemp(root.gpuTemp))
    parts.push(" " + Model.fmtPct(root.mem))
    parts.push("\uDB80\uDECA " + Model.fmtBarUsed(root.primaryVolume))
    // Fan: the hardest-working one, CPU duty or GPU fan %.
    if (root.loudestFan === "gpu")
      parts.push("\uDB80\uDE10 " + Model.fmtPct(root.gpuFan) + " GPU")
    else if (root.loudestFan === "cpu")
      parts.push("\uDB80\uDE10 " + (root.cpuFanDuty !== null ? Model.fmtPct(root.cpuFanDuty) : Model.fmtRpm(root.cpuFanRpm)))
    return parts.join(" | ")
  }

  function tooltipText() {
    var lines = []
    lines.push("CPU  " + Model.fmtPct(root.cpu) + "  " + Model.fmtTemp(root.cpuTemp)
      + "   (avg " + Model.fmtPct(root.cpuAvg) + "  " + Model.fmtTemp(root.cpuTempAvg) + ")")
    if (root.hasGpu)
      lines.push("GPU  " + Model.fmtPct(root.gpu) + "  " + Model.fmtTemp(root.gpuTemp)
        + "   (avg " + Model.fmtPct(root.gpuAvg) + "  " + Model.fmtTemp(root.gpuTempAvg) + ")")
    lines.push("MEM  " + Model.fmtPct(root.mem) + "   (avg " + Model.fmtPct(root.memAvg) + ")")
    lines.push("DISK " + (root.primaryVolume ? Model.fmtPct(root.primaryVolume.pct) + "   " : " ") + Model.fmtVolumeDetail(root.primaryVolume))
    if (root.hasCpuFan) {
      lines.push("")
      lines.push("CPU FAN  " + Model.fmtRpm(root.cpuFanRpm) + "  " + Model.fmtPct(root.cpuFanDuty)
        + "   (avg " + Model.fmtPct(root.cpuFanAvg) + ")")
      lines.push("  ← " + Model.cpuFanDriver({ cpuTemp: root.cpuTemp, cpu: root.cpu }, root.topProc))
    }
    if (root.hasGpuFan) {
      if (!root.hasCpuFan) lines.push("")
      lines.push("GPU FAN  " + Model.fmtPct(root.gpuFan) + (root.gpuFan === 0 ? " (idle stop)" : "")
        + "   (avg " + Model.fmtPct(root.gpuFanAvg) + ")")
      lines.push("  ← " + Model.gpuFanDriver({ gpuTemp: root.gpuTemp, gpu: root.gpu }))
    }
    return lines.join("\n")
  }

  // ---- popup panel routing (clock pattern) ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // Read-only diagnostics for tests/scripting. Reached via quickshell's
  // native IPC (NOT `omarchy-shell shell call`, which only routes to
  // panel/overlay plugins):
  // `quickshell --path /usr/share/omarchy/shell ipc call wartafak.sysmon debugState`.
  function debugState() {
    return JSON.stringify({
      opened: root.opened,
      cpu: root.cpu,
      cpuTemp: root.cpuTemp,
      gpu: root.gpu,
      gpuTemp: root.gpuTemp,
      gpuVendor: root.gpuVendor,
      gpuShort: root.gpuShort,
      cpuModel: root.cpuModel,
      cpuThreads: root.cpuThreads,
      cpuMaxGhz: root.cpuMaxGhz,
      mem: root.mem,
      memUsedKb: root.memUsedKb,
      memTotalKb: root.memTotalKb,
      cpuFanRpm: root.cpuFanRpm,
      cpuFanDuty: root.cpuFanDuty,
      gpuFan: root.gpuFan,
      loudestFan: root.loudestFan,
      hasGpu: root.hasGpu,
      sampleCount: root.sampleCount,
      cpuHistLen: root.cpuHist ? root.cpuHist.length : 0,
      memHistLen: root.memHist ? root.memHist.length : 0,
      processCount: root.processCount,
      volumes: root.volumes,
      scanFolders: root.scanResult ? root.scanResult.folders.length : 0,
      scanFailed: root.scanFailed
    })
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Sample processes as soon as the panel opens so the table is fresh.
  onOpenedChanged: { if (root.opened) root.refreshProcesses() }

  Component.onCompleted: refresh()

  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.procPollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { if (root.opened) root.refreshProcesses() }
  }

  Timer {
    interval: root.procIdlePollMs
    running: !root.opened && root.hasCpuFan
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshProcesses()
  }

  Timer {
    interval: root.storagePollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStorage()
  }

  Timer {
    id: scanHint
    interval: root.scanHintMs
    onTriggered: root.scanSlow = true
  }

  Process {
    id: statsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStats(text)
    }
  }

  Process {
    id: procProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProcesses(text)
    }
  }

  Process {
    id: storageProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumes = Model.parseVolumes(text)
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text)
    }
  }

  // Kill runs to completion fast; refresh the table right after so the
  // row disappears without waiting for the next poll.
  Process {
    id: killProc
    onExited: { if (root.opened) root.refreshProcesses() }
  }

  Process {
    id: copyProc
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "wartafak.sysmon"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function debugState(): string { return root.debugState() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.barText()
    tooltipText: root.tooltipText()
    horizontalMargin: 8.75
    verticalPadding: 8.75
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.refresh()
        root.refreshStorage()
      } else root.togglePanel()
    }
  }
}

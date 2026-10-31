import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// wartafak.sysmon popup: tabbed (Overview / CPU / GPU / Memory / Storage /
// Fans / Processes) so every view fits without scrolling; only the process list
// scrolls. Live data and histories live on the host BarWidget
// (hostWidget); this panel only renders them.
Panel {
  id: root
  moduleName: "wartafak.sysmon"
  ipcTarget: "wartafak.sysmon"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedForeground: Qt.darker(root.contentForeground, 1.4)
  readonly property color tempColor: hostWidget ? hostWidget.themeTemp : "#e0af68"
  readonly property color memColor: hostWidget ? hostWidget.themeGreen : "#9ece6a"
  readonly property color headerColor: hostWidget ? hostWidget.themePurple : "#ad8ee6"
  readonly property color storageColor: hostWidget ? hostWidget.themeCyan : "#449dab"

  readonly property bool hasGpu: hostWidget ? hostWidget.hasGpu : false
  readonly property bool hasCpuFan: hostWidget ? hostWidget.hasCpuFan : false
  readonly property bool hasGpuFan: hostWidget ? hostWidget.hasGpuFan : false
  readonly property bool hasFans: hasCpuFan || hasGpuFan

  // ---- tabs ----
  // Every open starts on Overview; tabs without data (no GPU, no fan
  // sensors) are left out, so number keys always map to what is shown.
  property string currentTab: "overview"
  readonly property var tabs: {
    var list = [{ id: "overview", label: "OVERVIEW" }, { id: "cpu", label: "CPU" }]
    if (hasGpu) list.push({ id: "gpu", label: "GPU" })
    list.push({ id: "memory", label: "MEM" })
    list.push({ id: "storage", label: "STORAGE" })
    if (hasFans) list.push({ id: "fans", label: "FANS" })
    list.push({ id: "procs", label: "PROCS " + (hostWidget ? hostWidget.processCount : 0) })
    return list
  }

  // Fresh numbers on every visit; the folder scan runs only from here.
  onCurrentTabChanged: {
    if (root.currentTab === "storage" && hostWidget) {
      hostWidget.refreshStorage()
      hostWidget.startScan()
    }
  }

  function tabIndex(id) {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].id === id) return i
    return 0
  }

  function selectTab(id) {
    root.currentTab = id
    keyCatcher.forceActiveFocus()
  }

  function stepTab(delta) {
    var i = (tabIndex(currentTab) + delta + tabs.length) % tabs.length
    selectTab(tabs[i].id)
  }

  onOpenedChanged: {
    if (root.opened) {
      root.currentTab = "overview"
      root.procQuery = ""
    }
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function windowTitle() {
    var n = hostWidget ? hostWidget.sampleCount : 0
    if (!n) return "COLLECTING SAMPLES…"
    var secs = Math.min(n * 2, root.rangeSec)
    var mm = Math.floor(secs / 60), ss = secs % 60
    return "LAST " + mm + "M " + (ss < 10 ? "0" + ss : ss) + "S · 2S SAMPLES"
  }

  function levelColor(pct) {
    var level = Model.storageLevel(pct)
    if (level === "critical") return Color.urgent
    return level === "warning" ? root.tempColor : root.storageColor
  }

  function cpuHeader() {
    if (!hostWidget) return "CPU"
    return Model.cpuTitle({ cpuModel: hostWidget.cpuModel, cpuThreads: hostWidget.cpuThreads, cpuMaxGhz: hostWidget.cpuMaxGhz })
  }

  function gpuHeader() {
    if (!hostWidget) return "GPU"
    return Model.gpuTitle({ gpuShort: hostWidget.gpuShort })
  }

  function memHeader() {
    if (!hostWidget) return "MEMORY"
    return Model.memTitle({ memTotalKb: hostWidget.memTotalKb })
  }

  function cpuFanLine() {
    if (!hostWidget) return ""
    return Model.cpuFanDriver({ cpuTemp: hostWidget.cpuTemp, cpu: hostWidget.cpu }, hostWidget.topProc)
  }

  function gpuFanLine() {
    if (!hostWidget) return ""
    return Model.gpuFanDriver({ gpuTemp: hostWidget.gpuTemp, gpu: hostWidget.gpu })
  }

  // Overview banner: the hardest-working fan and what it reacts to.
  function loudestTitle() {
    if (!hostWidget) return ""
    if (hostWidget.loudestFan === "gpu")
      return "Loudest: GPU fan " + Model.fmtPct(hostWidget.gpuFan)
    return "Loudest: CPU fan " + Model.fmtPct(hostWidget.cpuFanDuty) + " · " + Model.fmtRpm(hostWidget.cpuFanRpm)
  }

  function loudestDriver() {
    if (!hostWidget) return ""
    return "← " + (hostWidget.loudestFan === "gpu" ? gpuFanLine() : cpuFanLine())
  }

  // ---- time range (graphs + averages) ----
  // Kept across opens; the bar tooltip keeps its fixed 10-minute averages.
  property int rangeSec: 600
  readonly property int rangeSamples: Model.windowSamples(rangeSec, hostWidget ? hostWidget.pollMs / 1000 : 2)

  function win(history) {
    return Model.lastWindow(history, root.rangeSamples)
  }

  function wavg(history) {
    return Model.average(root.win(history))
  }

  function stepRange(delta) {
    var r = Model.RANGES
    var i = r.indexOf(root.rangeSec)
    if (i < 0) i = r.length - 1
    root.rangeSec = r[Math.max(0, Math.min(r.length - 1, i + delta))]
  }

  // ---- storage state (data lives on hostWidget) ----
  // Three cards fit without scrolling.
  readonly property var allVolumes: hostWidget ? hostWidget.volumes : []
  readonly property var shownVolumes: allVolumes.slice(0, 3)
  readonly property var mainVolume: hostWidget ? hostWidget.primaryVolume : null
  readonly property var scanResult: hostWidget ? hostWidget.scanResult : null
  readonly property var topFolders: scanResult ? scanResult.folders.slice(0, 5) : []
  readonly property bool scanFailed: hostWidget ? hostWidget.scanFailed : false
  readonly property bool scanSlow: hostWidget ? hostWidget.scanSlow : false

  // Last folder copied to the clipboard; its name flashes ✓ until cleared.
  property string copiedFolder: ""

  function copyFolder(name) {
    if (!hostWidget) return
    hostWidget.copyFolderPath(name)
    root.copiedFolder = name
    copyFlash.restart()
  }

  // ---- process table state (raw list lives on hostWidget) ----
  property string procSortKey: "cpu"
  property int procSortDir: -1
  property string procQuery: ""
  readonly property int procNumW: Style.space(52)
  readonly property int procMemW: Style.space(108)
  readonly property int procPidW: Style.space(58)
  readonly property int procBtnW: Style.space(46)
  readonly property var allProcs: hostWidget ? hostWidget.processes : []
  readonly property var shownProcs: Model.sortProcesses(Model.filterProcesses(allProcs, procQuery), procSortKey, procSortDir)
  readonly property var topByCpu: Model.sortProcesses(allProcs, "cpu", -1)
  readonly property var topByMem: Model.sortProcesses(allProcs, "mem", -1)
  // Last pid copied to the clipboard; the cell flashes ✓ until cleared.
  property int copiedPid: -1

  function procSortLabel(key, title) {
    var arrow = procSortKey === key ? (procSortDir === 1 ? " ▲" : " ▼") : ""
    return title + arrow
  }

  function toggleProcSort(key) {
    if (procSortKey === key) procSortDir = -procSortDir
    else {
      procSortKey = key
      procSortDir = key === "comm" || key === "pid" ? 1 : -1
    }
  }

  function copyPid(pid) {
    if (!hostWidget) return
    hostWidget.copyPid(pid)
    root.copiedPid = pid
    copyFlash.restart()
  }

  Timer {
    id: copyFlash
    interval: 1200
    onTriggered: {
      root.copiedPid = -1
      root.copiedFolder = ""
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(625), Style.space(665))

    // Left/Right (h/l) and 1–7 switch tabs, "/" jumps to the process
    // filter; Tab keeps switching between bar panels. Typing in the
    // filter blocks all of this.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: filterField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.stepTab(dx) }
      onTextKey: function(t) {
        var n = parseInt(t, 10)
        if (n >= 1 && n <= root.tabs.length) root.selectTab(root.tabs[n - 1].id)
        else if (t === "[" || t === "-") root.stepRange(-1)
        else if (t === "]" || t === "+" || t === "=") root.stepRange(1)
        else if (t === "/") {
          root.selectTab("procs")
          filterField.forceActiveFocus()
        }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "System Monitor"
          meta: root.currentTab === "storage" ? "UPDATES EVERY 60S" : root.windowTitle()
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        // ---------- Tab bar ----------
        Row {
          id: tabBar
          Layout.fillWidth: true
          spacing: Style.space(4)

          Repeater {
            model: root.tabs
            Button {
              required property var modelData
              width: (tabBar.width - tabBar.spacing * (root.tabs.length - 1)) / root.tabs.length
              text: modelData.label
              selected: root.currentTab === modelData.id
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(2)
              onClicked: root.selectTab(modelData.id)
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.contentForeground
        }

        // ---------- Time range ----------
        // Window for every graph and AVG value; hidden on the tabs with
        // neither (Storage, Processes).
        RowLayout {
          Layout.fillWidth: true
          visible: root.currentTab !== "procs" && root.currentTab !== "storage"
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "RANGE"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: Model.RANGES
            Button {
              required property var modelData
              text: Model.fmtRange(modelData)
              selected: root.rangeSec === modelData
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(2)
              tooltipText: "Show the last " + Model.fmtRange(modelData).toLowerCase()
              onClicked: root.rangeSec = modelData
            }
          }
        }

        // ---------- Pages ----------
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // ===== Overview =====
          Column {
            anchors.fill: parent
            spacing: Style.space(10)
            visible: root.currentTab === "overview"

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              OverviewCard {
                title: "CPU"
                hint: "details ›"
                value: hostWidget ? Model.fmtPct(hostWidget.cpu) : "--"
                sub: hostWidget ? Model.fmtTemp(hostWidget.cpuTemp) : "--"
                subColor: root.tempColor
                lineColor: Color.accent
                history: hostWidget ? root.win(hostWidget.cpuHist) : []
                target: "cpu"
              }
              OverviewCard {
                visible: root.hasGpu
                title: "GPU"
                hint: "details ›"
                value: hostWidget ? Model.fmtPct(hostWidget.gpu) : "--"
                sub: hostWidget ? Model.fmtTemp(hostWidget.gpuTemp) : "--"
                subColor: root.tempColor
                lineColor: Color.accent
                history: hostWidget ? root.win(hostWidget.gpuHist) : []
                target: "gpu"
              }
              OverviewCard {
                title: "MEMORY"
                hint: hostWidget ? Model.fmtMemDetail(hostWidget.memUsedKb, hostWidget.memTotalKb) + " ›" : "›"
                value: hostWidget ? Model.fmtPct(hostWidget.mem) : "--"
                lineColor: root.memColor
                history: hostWidget ? root.win(hostWidget.memHist) : []
                target: "memory"
              }
              OverviewCard {
                visible: root.hasFans
                title: "FANS"
                hint: (hostWidget && hostWidget.loudestFan === "gpu" ? "GPU fan" : "CPU fan") + " ›"
                value: !hostWidget ? "--"
                  : hostWidget.loudestFan === "gpu" ? Model.fmtPct(hostWidget.gpuFan)
                  : Model.fmtPct(hostWidget.cpuFanDuty)
                sub: hostWidget && hostWidget.loudestFan !== "gpu" ? Model.fmtRpm(hostWidget.cpuFanRpm) : ""
                subColor: root.contentForeground
                lineColor: root.tempColor
                history: !hostWidget ? []
                  : root.win(hostWidget.loudestFan === "gpu" ? hostWidget.gpuFanHist : hostWidget.cpuFanHist)
                target: "fans"
              }
            }

            // Storage strip: a bar, not a sparkline. Disk usage barely moves
            // inside a graph window.
            Rectangle {
              width: parent.width
              implicitHeight: stripCol.implicitHeight + Style.space(16)
              height: implicitHeight
              radius: Style.cornerRadius
              color: stripMouse.containsMouse
                ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.09)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
              border.width: 1
              border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

              MouseArea {
                id: stripMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectTab("storage")
              }

              Column {
                id: stripCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Style.space(8)
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: stripTitle.implicitHeight
                  Text {
                    id: stripTitle
                    textFormat: Text.PlainText
                    text: "STORAGE"
                    color: root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    anchors.right: parent.right
                    textFormat: Text.PlainText
                    text: "details ›"
                    color: root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Item {
                  width: parent.width
                  height: stripValue.implicitHeight
                  Text {
                    id: stripValue
                    textFormat: Text.PlainText
                    text: root.mainVolume ? Model.fmtPct(root.mainVolume.pct) : "--"
                    color: root.levelColor(root.mainVolume ? root.mainVolume.pct : null)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.baseline: stripValue.baseline
                    textFormat: Text.PlainText
                    text: Model.fmtVolumeDetail(root.mainVolume)
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                UsageBar {
                  fraction: root.mainVolume ? Model.fraction(root.mainVolume.pct, 100) : 0
                  barColor: root.levelColor(root.mainVolume ? root.mainVolume.pct : null)
                }
              }
            }

            // Loudest-fan banner.
            Rectangle {
              visible: root.hasFans
              width: parent.width
              implicitHeight: bannerCol.implicitHeight + Style.space(14)
              height: implicitHeight
              radius: Style.cornerRadius
              color: Qt.rgba(root.tempColor.r, root.tempColor.g, root.tempColor.b, 0.10)
              border.width: 1
              border.color: Qt.rgba(root.tempColor.r, root.tempColor.g, root.tempColor.b, 0.35)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectTab("fans")
              }

              Column {
                id: bannerCol
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "󰈐  " + root.loudestTitle()
                  color: root.tempColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.loudestDriver()
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            MiniProcList {
              title: "TOP PROCESSES"
              linkText: "All " + (hostWidget ? hostWidget.processCount : 0) + " ›"
              rows: root.topByCpu.slice(0, 5)
              showMem: true
            }
          }

          // ===== CPU =====
          Column {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentTab === "cpu"

            PanelSectionHeader {
              text: root.cpuHeader()
              width: parent.width
              elide: Text.ElideRight
              foreground: root.headerColor
              fontFamily: root.contentFontFamily
            }
            StatRow {
              label: "USAGE"
              now: hostWidget ? Model.fmtPct(hostWidget.cpu) : "--"
              avg: hostWidget ? Model.fmtPct(root.wavg(hostWidget.cpuHist)) : "--"
            }
            HistoryGraph {
              history: hostWidget ? root.win(hostWidget.cpuHist) : []
              lineColor: Color.accent
              unit: "%"
              graphHeight: Style.space(88)
            }
            StatRow {
              label: "TEMP"
              now: hostWidget ? Model.fmtTemp(hostWidget.cpuTemp) : "--"
              avg: hostWidget ? Model.fmtTemp(root.wavg(hostWidget.cpuTempHist)) : "--"
            }
            HistoryGraph {
              history: hostWidget ? root.win(hostWidget.cpuTempHist) : []
              lineColor: root.tempColor
              unit: "°"
              maxVal: 120
              graphHeight: Style.space(88)
            }
            FanDriver {
              visible: root.hasCpuFan
              text: hostWidget ? "Cooled by: CPU fan " + Model.fmtPct(hostWidget.cpuFanDuty) + " · " + Model.fmtRpm(hostWidget.cpuFanRpm) : ""
            }
            MiniProcList {
              title: "TOP BY CPU"
              linkText: "All processes ›"
              rows: root.topByCpu.slice(0, 3)
              showMem: false
            }
          }

          // ===== GPU =====
          Column {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentTab === "gpu"

            PanelSectionHeader {
              text: root.gpuHeader()
              width: parent.width
              elide: Text.ElideRight
              foreground: root.headerColor
              fontFamily: root.contentFontFamily
            }
            StatRow {
              label: "USAGE"
              now: hostWidget ? Model.fmtPct(hostWidget.gpu) : "--"
              avg: hostWidget ? Model.fmtPct(root.wavg(hostWidget.gpuHist)) : "--"
            }
            HistoryGraph {
              history: hostWidget ? root.win(hostWidget.gpuHist) : []
              lineColor: Color.accent
              unit: "%"
              graphHeight: Style.space(100)
            }
            StatRow {
              label: "TEMP"
              now: hostWidget ? Model.fmtTemp(hostWidget.gpuTemp) : "--"
              avg: hostWidget ? Model.fmtTemp(root.wavg(hostWidget.gpuTempHist)) : "--"
            }
            HistoryGraph {
              history: hostWidget ? root.win(hostWidget.gpuTempHist) : []
              lineColor: root.tempColor
              unit: "°"
              maxVal: 120
              graphHeight: Style.space(100)
            }
            FanDriver {
              visible: root.hasGpuFan
              text: hostWidget ? "Cooled by: GPU fan " + Model.fmtPct(hostWidget.gpuFan) + (hostWidget.gpuFan === 0 ? " (idle stop)" : "") : ""
            }
          }

          // ===== Memory =====
          Column {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentTab === "memory"

            PanelSectionHeader {
              text: root.memHeader()
              width: parent.width
              elide: Text.ElideRight
              foreground: root.headerColor
              fontFamily: root.contentFontFamily
            }
            StatRow {
              label: "USAGE"
              now: hostWidget ? Model.fmtPct(hostWidget.mem) : "--"
              avg: hostWidget ? Model.fmtPct(root.wavg(hostWidget.memHist)) : "--"
              extra: hostWidget ? Model.fmtMemDetail(hostWidget.memUsedKb, hostWidget.memTotalKb) : ""
            }
            HistoryGraph {
              history: hostWidget ? root.win(hostWidget.memHist) : []
              lineColor: root.memColor
              unit: "%"
              graphHeight: Style.space(130)
            }
            MiniProcList {
              title: "TOP BY MEMORY"
              linkText: "All processes ›"
              rows: root.topByMem.slice(0, 6)
              showMem: true
              memOnly: true
            }
          }

          // ===== Storage =====
          Column {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentTab === "storage"

            PanelSectionHeader {
              text: "STORAGE · " + root.allVolumes.length + (root.allVolumes.length === 1 ? " VOLUME" : " VOLUMES")
              width: parent.width
              foreground: root.headerColor
              fontFamily: root.contentFontFamily
            }

            Text {
              visible: root.allVolumes.length === 0
              textFormat: Text.PlainText
              text: "not available"
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.shownVolumes
              VolumeCard {}
            }

            // Scan header: "Scanning…" once slow, RETRY after a failure,
            // otherwise the total.
            Item {
              width: parent.width
              height: Math.max(folderTitle.implicitHeight, retryBtn.visible ? retryBtn.implicitHeight : 0)
              PanelSectionHeader {
                id: folderTitle
                text: "BIGGEST FOLDERS IN ~"
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.headerColor
                fontFamily: root.contentFontFamily
              }
              Text {
                visible: !root.scanFailed
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.scanSlow ? "Scanning…" : root.scanResult ? Model.fmtBytes(root.scanResult.total) + " total" : ""
                color: root.scanSlow ? root.storageColor : root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Button {
                id: retryBtn
                visible: root.scanFailed
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "RETRY"
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(2)
                onClicked: { if (hostWidget) hostWidget.startScan() }
              }
            }

            Repeater {
              model: root.topFolders
              FolderRow {}
            }

            // First scan: placeholder rows until results exist.
            Repeater {
              model: !root.scanResult && !root.scanFailed ? 5 : 0
              Rectangle {
                width: parent ? parent.width : 0
                height: Style.space(8)
                radius: height / 2
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)
              }
            }

            Text {
              visible: root.scanFailed
              width: parent.width
              textFormat: Text.PlainText
              text: root.scanResult ? "Scan failed · showing the last saved results" : "Scan failed"
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // ===== Fans =====
          // CPU fan duty = board PWM to the CPU_FAN header; the driver line
          // names what that fan is reacting to (fans can't report a cause).
          Column {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentTab === "fans"

            PanelSectionHeader {
              text: "FANS"
              width: parent.width
              foreground: root.headerColor
              fontFamily: root.contentFontFamily
            }
            StatRow {
              visible: root.hasCpuFan
              label: "CPU FAN"
              now: hostWidget ? Model.fmtPct(hostWidget.cpuFanDuty) : "--"
              avg: hostWidget ? Model.fmtPct(root.wavg(hostWidget.cpuFanHist)) : "--"
              extra: hostWidget ? Model.fmtRpm(hostWidget.cpuFanRpm) : ""
            }
            FanDriver {
              visible: root.hasCpuFan
              loudest: hostWidget ? hostWidget.loudestFan === "cpu" : false
              text: "← " + root.cpuFanLine()
            }
            HistoryGraph {
              visible: root.hasCpuFan
              history: hostWidget ? root.win(hostWidget.cpuFanHist) : []
              lineColor: root.tempColor
              unit: "%"
              graphHeight: Style.space(90)
            }
            StatRow {
              visible: root.hasGpuFan
              label: "GPU FAN"
              now: hostWidget ? Model.fmtPct(hostWidget.gpuFan) : "--"
              avg: hostWidget ? Model.fmtPct(root.wavg(hostWidget.gpuFanHist)) : "--"
              extra: hostWidget && hostWidget.gpuFan === 0 ? "idle stop" : ""
            }
            FanDriver {
              visible: root.hasGpuFan
              loudest: hostWidget ? hostWidget.loudestFan === "gpu" : false
              text: "← " + root.gpuFanLine()
            }
            HistoryGraph {
              visible: root.hasGpuFan
              history: hostWidget ? root.win(hostWidget.gpuFanHist) : []
              lineColor: Color.accent
              unit: "%"
              graphHeight: Style.space(90)
            }
          }

          // ===== Processes =====
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(6)
            visible: root.currentTab === "procs"

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              TextField {
                id: filterField
                Layout.fillWidth: true
                placeholderText: "Filter by name or PID…  ( / )"
                text: root.procQuery
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                onTextChanged: root.procQuery = text
                Keys.onEscapePressed: function(event) {
                  if (text !== "") text = ""
                  else keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }

              Text {
                textFormat: Text.PlainText
                text: root.shownProcs.length + " of " + root.allProcs.length
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Sortable column headers; column geometry mirrors ProcRow.
            Item {
              Layout.fillWidth: true
              Layout.rightMargin: Style.space(8)
              implicitHeight: Math.max(nameHead.implicitHeight, cpuHead.implicitHeight)

              SortHead {
                id: nameHead
                key: "comm"
                title: "PROCESS"
                horizontalAlignment: Text.AlignLeft
                anchors.left: parent.left
                anchors.right: pidHead.left
                anchors.rightMargin: Style.space(8)
              }
              Item {
                id: killHead
                width: root.procBtnW * 2
                height: 1
                anchors.right: parent.right
              }
              SortHead {
                id: memHead
                key: "mem"
                title: "MEM"
                width: root.procMemW
                anchors.right: killHead.left
              }
              SortHead {
                id: cpuHead
                key: "cpu"
                title: "CPU"
                width: root.procNumW
                anchors.right: memHead.left
              }
              SortHead {
                id: pidHead
                key: "pid"
                title: "PID"
                width: root.procPidW
                anchors.right: cpuHead.left
              }
            }

            ListView {
              id: procList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.shownProcs
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              delegate: ProcRow { width: procList.width - Style.space(8) }

              Text {
                visible: procList.count === 0
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.allProcs.length === 0 ? "sampling…" : "No process matches “" + root.procQuery + "”"
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---------- Footer: key hints ----------
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.currentTab === "storage"
            ? "Click a folder to copy its path · 1–" + root.tabs.length + " or ←/→ tabs · Esc close"
            : "1–" + root.tabs.length + " or ←/→ tabs · [ ] range · / filter · Esc close"
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // Overview card: title + hint, big value + sub, compact sparkline.
  // The whole card opens its tab.
  component OverviewCard: Rectangle {
    id: card
    property string title: ""
    property string hint: ""
    property string value: "--"
    property string sub: ""
    property color subColor: root.mutedForeground
    property color lineColor: Color.accent
    property var history: []
    property string target: ""

    Layout.fillWidth: true
    implicitHeight: cardCol.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: cardMouse.containsMouse
      ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.09)
      : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
    border.width: 1
    border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectTab(card.target)
    }

    Column {
      id: cardCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(8)
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: titleText.implicitHeight
        Text {
          id: titleText
          textFormat: Text.PlainText
          text: card.title
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          anchors.right: parent.right
          anchors.left: titleText.right
          anchors.leftMargin: Style.space(6)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: card.hint
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        spacing: Style.space(8)
        Text {
          id: valueText
          textFormat: Text.PlainText
          text: card.value
          color: card.lineColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          anchors.baseline: valueText.baseline
          textFormat: Text.PlainText
          text: card.sub
          color: card.subColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      HistoryGraph {
        compact: true
        history: card.history
        lineColor: card.lineColor
        graphHeight: Style.space(36)
      }
    }
  }

  // Thin horizontal usage bar; the fill covers fraction (0–1) of the width.
  component UsageBar: Rectangle {
    id: usageBar
    property real fraction: 0
    property color barColor: root.storageColor

    width: parent ? parent.width : 0
    height: Style.space(6)
    radius: height / 2
    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Math.max(usageBar.fraction > 0 ? usageBar.height : 0, parent.width * usageBar.fraction)
      radius: parent.radius
      color: usageBar.barColor
    }
  }

  // One volume: mount + filesystem, percent + free space, usage bar,
  // used/total, and the mounts that share its space.
  component VolumeCard: Rectangle {
    id: volumeCard
    required property var modelData
    readonly property var volume: modelData
    readonly property color levelColor: root.levelColor(volume.pct)

    width: parent ? parent.width : 0
    implicitHeight: volumeCol.implicitHeight + Style.space(16)
    height: implicitHeight
    radius: Style.cornerRadius
    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
    border.width: 1
    border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

    Column {
      id: volumeCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(8)
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      Item {
        width: parent.width
        height: mountText.implicitHeight
        Text {
          id: mountText
          textFormat: Text.PlainText
          text: volumeCard.volume.mount
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          anchors.right: parent.right
          anchors.baseline: mountText.baseline
          textFormat: Text.PlainText
          text: Model.fmtVolumeMeta(volumeCard.volume)
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Item {
        width: parent.width
        height: pctText.implicitHeight
        Text {
          id: pctText
          textFormat: Text.PlainText
          text: Model.fmtPct(volumeCard.volume.pct)
          color: volumeCard.levelColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          anchors.right: parent.right
          anchors.baseline: pctText.baseline
          textFormat: Text.PlainText
          text: Model.fmtBytes(volumeCard.volume.avail) + " free"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      UsageBar {
        fraction: Model.fraction(volumeCard.volume.pct, 100)
        barColor: volumeCard.levelColor
      }

      Item {
        width: parent.width
        height: usedText.implicitHeight
        Text {
          id: usedText
          textFormat: Text.PlainText
          text: Model.fmtBytes(volumeCard.volume.used) + " used"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: Model.fmtBytes(volumeCard.volume.size) + " total"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        visible: volumeCard.volume.shared.length > 0
        width: parent.width
        textFormat: Text.PlainText
        text: "Same space as " + volumeCard.volume.shared.join(", ")
        color: root.mutedForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // One scanned folder: name, share of the home total, size. Clicking the
  // name copies its path and flashes ✓ until the timer clears it.
  component FolderRow: Item {
    id: folderRow
    required property var modelData

    width: parent ? parent.width : 0
    height: Math.max(folderName.implicitHeight, Style.space(20))

    Text {
      id: folderName
      width: Style.space(120)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.copiedFolder === folderRow.modelData.name ? "✓ Copied" : String(folderRow.modelData.name || "")
      color: root.copiedFolder === folderRow.modelData.name ? Color.accent : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.copyFolder(folderRow.modelData.name)
      }
    }
    Item {
      anchors.left: folderName.right
      anchors.right: folderSize.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(6)
      UsageBar {
        fraction: Model.fraction(folderRow.modelData.bytes, root.scanResult ? root.scanResult.total : 0)
      }
    }
    Text {
      id: folderSize
      width: Style.space(64)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: Model.fmtBytes(folderRow.modelData.bytes)
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
    }
  }

  // Short ranked process list with a link to the Processes tab.
  component MiniProcList: Column {
    id: mini
    property string title: ""
    property string linkText: ""
    property var rows: []
    property bool showMem: true
    property bool memOnly: false

    width: parent ? parent.width : 0
    spacing: Style.space(2)

    Item {
      width: parent.width
      height: Math.max(miniTitle.implicitHeight, miniLink.implicitHeight)
      PanelSectionHeader {
        id: miniTitle
        text: mini.title
        foreground: root.headerColor
        fontFamily: root.contentFontFamily
      }
      Text {
        id: miniLink
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: mini.linkText
        color: Color.accent
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.selectTab("procs")
        }
      }
    }

    Repeater {
      model: mini.rows
      Item {
        required property var modelData
        width: mini.width
        height: Math.max(rowName.implicitHeight, Style.space(22))

        Text {
          id: rowName
          anchors.left: parent.left
          anchors.right: rowCpu.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: String(modelData.comm || "")
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          id: rowCpu
          visible: !mini.memOnly
          width: mini.memOnly ? 0 : root.procNumW
          anchors.right: rowMem.left
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: Model.fmtPct(modelData.cpu)
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          id: rowMem
          visible: mini.showMem
          width: mini.showMem ? root.procMemW + Style.space(16) : 0
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: Model.fmtProcMem(modelData)
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }
      }
    }

    Text {
      visible: mini.rows.length === 0
      textFormat: Text.PlainText
      text: "sampling…"
      color: root.mutedForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Clickable process-table column header.
  component SortHead: Text {
    id: sortHead
    property string key: ""
    property string title: ""
    textFormat: Text.PlainText
    text: root.procSortLabel(key, title)
    color: root.procSortKey === key ? root.contentForeground : root.mutedForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    horizontalAlignment: Text.AlignRight
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    elide: Text.ElideRight
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleProcSort(sortHead.key)
    }
  }

  // "LABEL   NOW x   AVG <range> y" row with optional trailing detail.
  component StatRow: Item {
    id: statRow
    required property string label
    required property string now
    required property string avg
    property string extra: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(nowText.implicitHeight, avgText.implicitHeight)

    Text {
      id: labelText
      textFormat: Text.PlainText
      text: statRow.label
      color: root.mutedForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: nowText
      textFormat: Text.PlainText
      text: "NOW " + statRow.now + (statRow.extra !== "" ? "  ·  " + statRow.extra : "")
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.horizontalCenterOffset: -Style.space(40)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Text {
      id: avgText
      textFormat: Text.PlainText
      text: "AVG " + Model.fmtRange(root.rangeSec) + " " + statRow.avg
      color: root.mutedForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // "← CPU 73° · 45% load · top: cargo 30%" under a fan row; the
  // hardest-working fan is highlighted.
  component FanDriver: Text {
    property bool loudest: false
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    text: ""
    color: loudest ? root.tempColor : root.mutedForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: loudest
    elide: Text.ElideRight
    leftPadding: Style.space(6)
  }

  // One process row: "name · pid" plus CPU/MEM and TERM/KILL actions.
  // Right-hand column geometry mirrors the SortHead row above.
  // NOTE: the row object arrives as required modelData (auto-filled by the
  // ListView). Do NOT pass it from the delegate site (`proc: modelData`
  // fails: bindings on an inline `component` instance resolve in the
  // definition scope, where modelData does not exist).
  component ProcRow: Item {
    id: procRow
    required property var modelData
    readonly property var proc: modelData

    width: parent ? parent.width : 0
    implicitHeight: Math.max(nameText.implicitHeight, termBtn.height, killBtn.height) + Style.space(4)
    height: implicitHeight

    Text {
      id: nameText
      textFormat: Text.PlainText
      text: String(procRow.proc.comm || "")
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.right: pidText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    // Click copies the pid; flashes ✓ until the timer clears it.
    Text {
      id: pidText
      textFormat: Text.PlainText
      text: root.copiedPid === procRow.proc.pid ? "✓" : String(procRow.proc.pid)
      color: root.copiedPid === procRow.proc.pid ? Color.accent : root.mutedForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignRight
      width: root.procPidW
      anchors.right: cpuText.left
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.copyPid(procRow.proc.pid)
      }
    }

    Button {
      id: killBtn
      text: "KILL"
      foreground: Color.urgent
      fontFamily: root.contentFontFamily
      fontSize: Style.font.caption
      horizontalPadding: Style.space(4)
      verticalPadding: Style.space(2)
      width: root.procBtnW
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      tooltipText: "Force kill " + procRow.proc.comm + " (" + procRow.proc.pid + ", SIGKILL)"
      onClicked: { if (hostWidget) hostWidget.killProcess(procRow.proc.pid, true) }
    }

    Button {
      id: termBtn
      text: "TERM"
      fontFamily: root.contentFontFamily
      fontSize: Style.font.caption
      horizontalPadding: Style.space(4)
      verticalPadding: Style.space(2)
      width: root.procBtnW
      anchors.right: killBtn.left
      anchors.verticalCenter: parent.verticalCenter
      tooltipText: "Terminate " + procRow.proc.comm + " (" + procRow.proc.pid + ", SIGTERM)"
      onClicked: { if (hostWidget) hostWidget.killProcess(procRow.proc.pid, false) }
    }

    Text {
      id: memText
      textFormat: Text.PlainText
      text: Model.fmtProcMem(procRow.proc)
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignRight
      width: root.procMemW
      anchors.right: termBtn.left
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Text {
      id: cpuText
      textFormat: Text.PlainText
      text: Model.fmtPct(procRow.proc.cpu)
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignRight
      width: root.procNumW
      anchors.right: memText.left
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }
  }

  // Line graph of the last N samples. Nulls render as gaps so missing
  // polls don't drag the line to zero. Y ticks run from maxVal down to
  // minVal in tickStep increments, one gridline + label per tick.
  // compact: sparkline mode for overview cards (no axis, no grid).
  component HistoryGraph: Item {
    id: graph
    property var history: []
    property color lineColor: Color.accent
    property real minVal: 0
    property real maxVal: 100
    property real tickStep: 25
    property bool compact: false
    property real graphHeight: Style.space(120)
    // Unit suffix for the Y axis labels, e.g. "%" for usage, "°" for temp.
    property string unit: ""

    // Ticks land on multiples of tickStep within [minVal, maxVal], going
    // down from the highest fitting multiple (so a 0–120 scale with step
    // 25 ticks 100/75/50/25/0, leaving 120 as unlabeled headroom).
    readonly property real topTick: Math.floor(graph.maxVal / graph.tickStep) * graph.tickStep
    readonly property int tickCount: Math.max(2, Math.floor((graph.topTick - graph.minVal) / graph.tickStep) + 1)

    width: parent ? parent.width : 0
    implicitHeight: graph.graphHeight
    height: graph.graphHeight

    function tickLabel(v) {
      var n = Number(v)
      if (!isFinite(n)) return "--"
      return (n % 1 === 0 ? String(n) : n.toFixed(1)) + graph.unit
    }

    function tickY(tickValue, labelHeight) {
      var y = Model.yFor(tickValue, graph.minVal, graph.maxVal, graph.height - 4) + 2 - labelHeight / 2
      return Math.max(0, Math.min(graph.height - labelHeight, y))
    }

    // Y axis ticks in the left gutter, each centered on its gridline.
    Repeater {
      model: graph.compact ? 0 : graph.tickCount
      Text {
        required property int index
        readonly property real tickValue: graph.topTick - index * graph.tickStep
        textFormat: Text.PlainText
        text: graph.tickLabel(tickValue)
        color: root.mutedForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        width: Style.space(26)
        x: 0
        y: graph.tickY(tickValue, implicitHeight)
      }
    }

    Canvas {
      id: canvas
      anchors.fill: parent
      anchors.leftMargin: graph.compact ? 0 : Style.space(30)
      renderStrategy: Canvas.Cooperative

      onPaint: {
        var ctx = getContext("2d")
        var w = width, h = height
        ctx.clearRect(0, 0, w, h)
        var hist = graph.history || []
        var n = hist.length
        if (n === 0) return

        // grid: one faint line per Y tick, aligned with the labels
        if (!graph.compact) {
          ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)
          ctx.lineWidth = 1
          for (var ti = 0; ti < graph.tickCount; ti++) {
            var tick = graph.topTick - ti * graph.tickStep
            var gy = Math.round(Model.yFor(tick, graph.minVal, graph.maxVal, h - 4)) + 2 + 0.5
            ctx.beginPath()
            ctx.moveTo(0, gy)
            ctx.lineTo(w, gy)
            ctx.stroke()
          }
        }

        // "now" is on the right; oldest on the left. Stretch the stored
        // window across the full width.
        var max = Math.max(2, n)
        ctx.strokeStyle = graph.lineColor
        ctx.lineWidth = 1.5
        ctx.lineJoin = "round"
        ctx.beginPath()
        var penDown = false
        for (var i = 0; i < n; i++) {
          var v = hist[i]
          if (typeof v !== "number" || !isFinite(v)) { penDown = false; continue }
          var x = (i / (max - 1)) * w
          var y = Model.yFor(v, graph.minVal, graph.maxVal, h - 4) + 2
          if (!penDown) { ctx.moveTo(x, y); penDown = true }
          else ctx.lineTo(x, y)
        }
        ctx.stroke()
      }

      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      // Hidden tabs skip repaints; catch up when the tab is shown.
      onVisibleChanged: if (visible) requestPaint()
      Connections {
        target: graph
        function onHistoryChanged() { if (canvas.visible) canvas.requestPaint() }
        function onLineColorChanged() { canvas.requestPaint() }
      }
      Connections {
        target: root
        function onContentForegroundChanged() { canvas.requestPaint() }
      }
    }

    Text {
      visible: !graph.compact && (!graph.history || graph.history.length === 0)
      textFormat: Text.PlainText
      text: "collecting…"
      color: root.mutedForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      anchors.centerIn: parent
    }
  }
}

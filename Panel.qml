import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Popup for the Print Center bar pill: the configured printers (with ink
// levels), the active queue with per-job cancel / hold / release, "set
// default" and "test page" per printer, and an "add a network printer"
// expander backed by `print-center discover`.
//
// All live numbers come from the headless Service.qml via `serviceFor`;
// actions shell out to bin/print-center through the service's runAction().
Panel {
  id: root
  moduleName: "io.github.dreed47.print-center"
  // The headless service owns the short "print-center" IPC target; the popup
  // takes the full plugin id so the two handlers do not collide.
  ipcTarget: "io.github.dreed47.print-center"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false
  property bool popoutSwitchClosing: false

  readonly property string pluginId: "io.github.dreed47.print-center"
  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor(pluginId) : null

  // ---- service-backed state --------------------------------------
  readonly property bool cliMissing: svc ? svc.cliMissing === true : false
  readonly property bool cupsUp: svc ? svc.cupsUp !== false : true
  readonly property var printers: svc ? svc.printers : []
  readonly property var jobs: svc ? svc.jobs : []
  readonly property var recentCompleted: svc ? svc.recentCompleted : []
  readonly property string defaultPrinter: svc ? String(svc.defaultPrinter || "") : ""
  readonly property string worstState: svc ? String(svc.worstState || "ok") : "ok"
  readonly property string summary: svc ? String(svc.summary || "") : ""
  readonly property int activeJobs: svc ? (svc.activeJobs || 0) : 0

  readonly property string printerGlyph: String.fromCharCode(0xf02f)
  readonly property string bullet: String.fromCharCode(0x2022)

  // ---- bar-pill tooltip / right-click text ----------------------
  readonly property string tooltip: {
    if (cliMissing) return "Print Center — Node.js is required (omarchy pkg add nodejs)"
    if (!cupsUp) return "Print Center — the CUPS service is not running"
    var d = defaultPrinter || (printers.length ? printers[0].name : "no printer")
    return "Print Center — " + d + " · " + summary
  }
  function statusLines() {
    if (cliMissing) return ["Print Center", "Node.js is required: omarchy pkg add nodejs"]
    if (!cupsUp) return ["Print Center", "The CUPS service is not running."]
    var out = ["Print Center — " + summary]
    for (var i = 0; i < printers.length; i++) {
      var p = printers[i]
      var line = (p.isDefault ? "* " : "  ") + p.name + "  [" + p.state + "]"
      if (p.alerts && p.alerts.length) line += "  — " + p.alerts[0].text
      out.push(line)
    }
    if (jobs.length) out.push(jobs.length + (jobs.length === 1 ? " job in the queue" : " jobs in the queue"))
    return out
  }
  readonly property string statusGlyph: printerGlyph

  // ---- actions ------------------------------------------------
  function act(args) { if (svc) svc.runAction(args) }
  function cancelJob(id) { act(["cancel", id]) }
  function holdJob(id) { act(["hold", id]) }
  function releaseJob(id) { act(["release", id]) }
  function clearQueue() { act(["cancel", "--all"]) }
  function makeDefault(name) { act(["default", name]) }
  function testPage(name) { act(["testpage", name]) }
  function openSettings() { if (svc) svc.runAction(["open-settings"]) }
  function addPrinter(d) {
    var args = ["add", "--uri", String(d.uri), "--name", String(d.queue), "--info", String(d.display || d.queue)]
    if (d.location) args.push("--location", String(d.location))
    act(args)
  }

  function refresh() {
    if (svc) svc.pollSoon()
    if (root.showDiscover) root.runDiscover()
    if (root.tab === "scan") root.checkScanSupport()
  }

  onOpenedChanged: if (root.opened) root.refresh()

  // ---- tabs -------------------------------------------------
  property string tab: "printers"   // "printers" | "scan"
  function selectTab(t) {
    root.tab = t
    if (t === "scan") root.checkScanSupport()
  }

  // ---- discover (this panel's own call) -----------------------
  property bool showDiscover: false
  property bool discovering: false
  property var discovered: []
  property string discoverError: ""

  function toggleDiscover() {
    root.showDiscover = !root.showDiscover
    if (root.showDiscover && root.discovered.length === 0) root.runDiscover()
  }
  function runDiscover() {
    if (!svc || discoverProc.running) return
    root.discovering = true
    discoverProc.command = ["node", svc.cli, "discover", "--json"]
    discoverProc.running = true
  }
  Process {
    id: discoverProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.discovering = false
        var body = String(text || "").trim()
        if (body === "") { root.discoverError = "no response"; return }
        try {
          root.discovered = JSON.parse(body) || []
          root.discoverError = ""
        } catch (e) {
          root.discoverError = "could not read the device list"
        }
      }
    }
  }

  // ---- scanning (this panel's own calls) ----------------------
  property var scanSupport: ({ scanimage: true, img2pdf: true, ready: true, pdf: true, missing: [] })
  property bool scanSupportKnown: false
  property var scanners: []
  property bool scannersLoading: false
  property string scanDevice: ""
  property var scanCaps: ({})
  property string scanMode: ""
  property int scanResolution: 300
  property string scanSource: ""
  property string scanFormat: (svc && svc.cfg) ? String(svc.cfg.scanFormat || "pdf") : "pdf"
  property bool scanning: false
  property int scanPct: 0
  property int scanPage: 0
  property string scanError: ""
  property var scanResult: null      // { path, pages, format, pageCount }

  readonly property string scanDir: (svc && svc.cfg) ? String(svc.cfg.scanDir || "~/Pictures/Scans") : "~/Pictures/Scans"
  readonly property var scanModes: (scanCaps && scanCaps.modes) ? scanCaps.modes : ["Color", "Gray"]
  readonly property var scanResolutions: (scanCaps && scanCaps.resolutions) ? scanCaps.resolutions : [150, 300, 600]
  readonly property var scanSources: (scanCaps && scanCaps.sources) ? scanCaps.sources : []

  function checkScanSupport() {
    if (!svc || scanSupportProc.running) return
    scanSupportProc.command = ["node", svc.cli, "scan-support", "--json"]
    scanSupportProc.running = true
  }
  Process {
    id: scanSupportProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.scanSupport = JSON.parse(String(text).trim()) || root.scanSupport } catch (e) {}
        root.scanSupportKnown = true
        if (root.scanSupport.ready && root.scanners.length === 0 && !root.scannersLoading)
          root.loadScanners()
      }
    }
  }

  function installScanSupport() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "echo 'Installing scanning support (SANE + img2pdf)…'; omarchy-pkg-add "
      + (root.scanSupport.missing && root.scanSupport.missing.length
         ? root.scanSupport.missing.join(" ") : "sane sane-airscan img2pdf")])
  }

  function loadScanners() {
    if (!svc || scannersProc.running) return
    root.scannersLoading = true
    root.scanError = ""
    scannersProc.command = ["node", svc.cli, "scanners", "--json"]
    scannersProc.running = true
  }
  Process {
    id: scannersProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.scannersLoading = false
        try { root.scanners = JSON.parse(String(text).trim()) || [] } catch (e) { root.scanners = [] }
        if (root.scanners.length && root.scanDevice === "") root.selectScanner(root.scanners[0].id)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (String(text).trim() !== "") root.scanError = shortErr(String(text)) }
    }
  }

  function selectScanner(id) {
    root.scanDevice = id
    root.scanCaps = ({})
    if (!svc || capsProc.running) return
    capsProc.command = ["node", svc.cli, "scan-caps", "--device", id, "--json"]
    capsProc.running = true
  }
  Process {
    id: capsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var c = JSON.parse(String(text).trim()) || {}
          root.scanCaps = c
          var d = c.defaults || {}
          root.scanMode = d.mode || (c.modes && c.modes[0]) || "Color"
          root.scanResolution = d.resolution || 300
          root.scanSource = d.source || ""
        } catch (e) {}
      }
    }
  }

  function doScan() {
    if (!svc || scanProc.running || root.scanDevice === "") return
    root.scanning = true
    root.scanPct = 0
    root.scanPage = 0
    root.scanError = ""
    root.scanResult = null
    var args = ["node", svc.cli, "scan", "--device", root.scanDevice,
      "--format", root.scanFormat, "--out", root.scanDir,
      "--mode", root.scanMode, "--resolution", String(root.scanResolution)]
    if (root.scanSource !== "") args.push("--source", root.scanSource)
    scanProc.command = args
    scanProc.running = true
  }
  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var r = JSON.parse(String(text).trim())
          if (r && r.path) root.scanResult = r
        } catch (e) {}
      }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        var m = String(line).match(/^PROGRESS (.+)$/)
        if (m) {
          try {
            var o = JSON.parse(m[1])
            if (o.progress !== undefined) root.scanPct = o.progress
            if (o.page !== undefined) root.scanPage = o.page
          } catch (e) {}
        } else if (/error|failed|cannot|no such/i.test(line)) {
          root.scanError = root.shortErr(line)
        }
      }
    }
    onExited: function (code) {
      root.scanning = false
      if (code !== 0 && !root.scanResult && root.scanError === "")
        root.scanError = "scan failed (exit " + code + ")"
      if (root.scanResult) root.scanError = ""
    }
  }

  function shortErr(s) {
    var t = String(s || "").trim().split("\n").filter(function (x) { return x !== "" })
    return t.length ? t[t.length - 1].replace(/^print-center:\s*/, "") : ""
  }
  function openScan(path) {
    if (path) Quickshell.execDetached(["xdg-open", String(path)])
  }
  function openScanFolder() {
    Quickshell.execDetached(["xdg-open", root.scanDir.replace(/^~/, String(Quickshell.env("HOME") || ""))])
  }

  // ---- "Nm ago" ticker while open ---------------------------
  property double nowMs: Date.now()
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onRunningChanged: if (running) root.nowMs = Date.now()
    onTriggered: root.nowMs = Date.now()
  }
  Timer {
    interval: 8000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- lifecycle -------------------------------------------
  function open() { openedFromHotkey = false; root.controller.show(); root.refresh() }
  function openFromHotkey() { openedFromHotkey = true; root.controller.show(); root.refresh() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.openFromHotkey() }
  function closeForPopoutSwitch() {
    root.popoutSwitchClosing = true
    root.controller.hide()
    Qt.callLater(function () { root.popoutSwitchClosing = false })
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function scan(): void { root.selectTab("scan"); root.openFromHotkey() }
  }

  // ---- UI -------------------------------------------------
  readonly property color fg: root.bar ? root.bar.foreground : "#e0e0e0"
  readonly property color dim: root.bar ? Qt.darker(fg, 1.5) : "#909090"
  readonly property color urgent: root.bar ? root.bar.urgent : "#e06c75"
  readonly property string mono: root.bar ? root.bar.fontFamily : "monospace"

  function sevColor(sev) {
    return sev === "error" ? root.urgent : (sev === "warn" ? Color.accent : root.dim)
  }
  function relTime(ms) {
    if (!ms) return ""
    var s = Math.floor((root.nowMs - ms) / 1000)
    if (s < 45) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(col.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: col
        width: parent.width
        spacing: Style.space(12)

        // ---- header ------------------------------------------
        Item {
          width: parent.width
          height: Style.space(24)
          Text {
            id: titleText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.printerGlyph + "  Print Center"
            color: root.fg
            font.family: root.mono
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            anchors.left: titleText.right
            anchors.right: refreshBtn.left
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: root.summary
            elide: Text.ElideLeft
            color: root.sevColor(root.worstState)
            font.family: root.mono
            font.pixelSize: Style.font.caption
          }
          Text {
            id: refreshBtn
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCharCode(0xf021)   // fa-refresh
            color: refreshArea.containsMouse ? Color.accent : root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            MouseArea {
              id: refreshArea
              anchors.fill: parent
              anchors.margins: -Style.space(5)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh()
            }
          }
        }

        // ---- tab strip -------------------------------------
        Row {
          width: parent.width
          spacing: Style.space(16)
          Repeater {
            model: [
              { key: "printers", label: "Printers" },
              { key: "scan", label: "Scan" }
            ]
            Text {
              required property var modelData
              text: modelData.label
              color: root.tab === modelData.key ? Color.accent : root.dim
              font.family: root.mono
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
              font.bold: root.tab === modelData.key
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectTab(modelData.key)
              }
            }
          }
        }

        // ---- banners ----------------------------------------
        Rectangle {
          visible: root.cliMissing
          width: parent.width
          height: visible ? nodeMsg.implicitHeight + Style.space(14) : 0
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: root.urgent
          Text {
            id: nodeMsg
            x: Style.space(10); y: Style.space(7)
            width: parent.width - Style.space(20)
            wrapMode: Text.WordWrap
            text: "Node.js is required and was not found.\nInstall it with:  omarchy pkg add nodejs"
            color: root.fg
            font.family: root.mono
            font.pixelSize: Style.font.caption
          }
        }
        Rectangle {
          visible: !root.cliMissing && !root.cupsUp
          width: parent.width
          height: visible ? cupsMsg.implicitHeight + Style.space(14) : 0
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: root.urgent
          Text {
            id: cupsMsg
            x: Style.space(10); y: Style.space(7)
            width: parent.width - Style.space(20)
            wrapMode: Text.WordWrap
            text: "The CUPS service is not running.\nStart it with:  sudo systemctl enable --now cups"
            color: root.fg
            font.family: root.mono
            font.pixelSize: Style.font.caption
          }
        }

        // ================= PRINTERS =================
        Column {
          visible: root.tab === "printers" && !root.cliMissing && root.cupsUp
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            text: "PRINTERS"
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            visible: root.printers.length === 0
            width: parent.width
            text: "No printers configured. Add one below."
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.printers
            Rectangle {
              required property var modelData
              width: col.width
              height: pRow.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: Qt.darker(root.fg, 1.8)

              Column {
                id: pRow
                x: Style.space(8)
                y: Style.space(6)
                width: parent.width - Style.space(16)
                spacing: Style.space(3)

                // name + state + default
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    text: String.fromCharCode(modelData.state === "stopped" ? 0xf04c
                      : (modelData.state === "processing" ? 0xf02f : 0xf111))
                    color: modelData.state === "stopped" ? Color.accent
                      : ((modelData.alerts && modelData.alerts.length)
                        ? root.sevColor(modelData.alerts[0].severity)
                        : root.dim)
                    font.family: root.mono
                    font.pixelSize: Style.font.caption - 2
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.name
                    color: root.fg
                    font.family: root.mono
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    visible: modelData.isDefault
                    text: "default"
                    color: Color.accent
                    font.family: root.mono
                    font.pixelSize: Style.font.caption - 1
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Item { width: 1; height: 1 }
                }

                // model + alert
                Text {
                  width: parent.width
                  text: (modelData.alerts && modelData.alerts.length)
                    ? modelData.alerts[0].text
                    : (modelData.makeAndModel || modelData.info || "")
                  color: (modelData.alerts && modelData.alerts.length)
                    ? root.sevColor(modelData.alerts[0].severity) : root.dim
                  font.family: root.mono
                  font.pixelSize: Style.font.caption - 1
                  elide: Text.ElideRight
                }

                // ink levels
                Row {
                  visible: (modelData.markers || []).length > 0
                  width: parent.width
                  spacing: Style.space(8)
                  Repeater {
                    model: modelData.markers || []
                    Row {
                      required property var modelData
                      spacing: Style.space(3)
                      Rectangle {
                        width: Style.space(6); height: Style.space(6)
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: modelData.level >= 0 && modelData.level <= modelData.low
                          ? root.urgent
                          : (modelData.level >= 0 && modelData.level <= modelData.low + 15 ? Color.accent : root.dim)
                      }
                      Text {
                        text: modelData.level >= 0 ? modelData.level + "%" : "?"
                        color: root.dim
                        font.family: root.mono
                        font.pixelSize: Style.font.caption - 2
                      }
                    }
                  }
                }

                // per-printer actions
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  topPadding: Style.space(2)

                  PcMiniButton {
                    visible: !modelData.isDefault
                    label: "Set default"
                    onTapped: root.makeDefault(modelData.name)
                  }
                  PcMiniButton {
                    label: "Test page"
                    onTapped: root.testPage(modelData.name)
                  }
                }
              }
            }
          }
        }

        // ================= QUEUE =================
        Column {
          visible: root.tab === "printers" && !root.cliMissing && root.cupsUp
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            text: "QUEUE" + (root.jobs.length ? "  " + root.bullet + "  " + root.jobs.length : "")
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            visible: root.jobs.length === 0
            width: parent.width
            text: root.recentCompleted.length
              ? ("Empty. Last: " + (root.recentCompleted[0].title || "job "
                + root.recentCompleted[0].idNum) + " " + root.relTime(root.recentCompleted[0].submittedAt))
              : "Empty."
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.jobs
            Rectangle {
              required property var modelData
              width: col.width
              height: jRow.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: Qt.darker(root.fg, 1.8)

              Column {
                id: jRow
                x: Style.space(8)
                y: Style.space(6)
                width: parent.width - Style.space(16)
                spacing: Style.space(3)

                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    text: modelData.state === "held" ? String.fromCharCode(0xf04c)
                      : (modelData.state === "processing" ? String.fromCharCode(0xf04b)
                        : String.fromCharCode(0xf017))
                    color: modelData.state === "held" ? Color.accent : root.dim
                    font.family: root.mono
                    font.pixelSize: Style.font.caption - 1
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.title || ("job " + modelData.idNum)
                    color: root.fg
                    font.family: root.mono
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - Style.space(90))
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                Text {
                  width: parent.width
                  text: modelData.printer + "  " + root.bullet + "  " + modelData.state
                    + "  " + root.bullet + "  " + root.relTime(modelData.submittedAt)
                  color: root.dim
                  font.family: root.mono
                  font.pixelSize: Style.font.caption - 1
                }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  topPadding: Style.space(2)
                  PcMiniButton {
                    label: modelData.state === "held" ? "Release" : "Hold"
                    onTapped: modelData.state === "held"
                      ? root.releaseJob(modelData.id) : root.holdJob(modelData.id)
                  }
                  PcMiniButton {
                    label: "Cancel"
                    danger: true
                    onTapped: root.cancelJob(modelData.id)
                  }
                }
              }
            }
          }

          PcMiniButton {
            visible: root.jobs.length > 1
            label: "Clear the whole queue"
            danger: true
            onTapped: root.clearQueue()
          }
        }

        // ================= ADD A PRINTER =================
        Column {
          visible: root.tab === "printers" && !root.cliMissing && root.cupsUp
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            text: (root.showDiscover ? String.fromCharCode(0xf078) : String.fromCharCode(0xf054))
              + "  Add a network printer"
            color: Color.accent
            font.family: root.mono
            font.pixelSize: Style.font.caption
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleDiscover()
            }
          }

          Column {
            visible: root.showDiscover
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: root.discovering || root.discoverError !== "" || root.discovered.length === 0
              width: parent.width
              text: root.discovering ? "scanning the network…"
                : (root.discoverError !== "" ? "Couldn't scan: " + root.discoverError
                  : "Nothing found on the network.")
              color: root.dim
              font.family: root.mono
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.discovered
              Rectangle {
                required property var modelData
                width: col.width
                height: dRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: Qt.darker(root.fg, 1.8)
                Row {
                  id: dRow
                  x: Style.space(8)
                  y: Style.space(6)
                  width: parent.width - Style.space(16)
                  spacing: Style.space(8)
                  Column {
                    width: parent.width - Style.space(78)
                    spacing: Style.space(1)
                    Text {
                      width: parent.width
                      text: modelData.display
                      color: root.fg
                      font.family: root.mono
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      text: (modelData.model || modelData.host || modelData.uri)
                        + (modelData.driverless ? "  " + root.bullet + " driverless" : "")
                      color: root.dim
                      font.family: root.mono
                      font.pixelSize: Style.font.caption - 2
                      elide: Text.ElideRight
                    }
                  }
                  PcMiniButton {
                    anchors.verticalCenter: parent.verticalCenter
                    label: modelData.alreadyAdded ? "Added" : "Add"
                    enabled: !modelData.alreadyAdded
                    onTapped: root.addPrinter(modelData)
                  }
                }
              }
            }
          }
        }

        // ================= SCAN =================
        Column {
          visible: root.tab === "scan" && !root.cliMissing
          width: parent.width
          spacing: Style.space(10)

          // --- tools not installed ---
          Column {
            visible: root.scanSupportKnown && !root.scanSupport.ready
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Scanning needs the sane, sane-airscan and img2pdf packages."
              color: root.fg
              font.family: root.mono
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: (root.scanSupport.missing || []).length > 0
              width: parent.width
              text: "missing: " + (root.scanSupport.missing || []).join(", ")
              color: root.dim
              font.family: root.mono
              font.pixelSize: Style.font.caption - 1
            }
            PcMiniButton {
              label: "Install scanning support"
              onTapped: root.installScanSupport()
            }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "A terminal opens for the install; re-open this panel when it finishes."
              color: Qt.darker(root.dim, 1.1)
              font.family: root.mono
              font.pixelSize: Style.font.caption - 2
            }
          }

          // --- ready ---
          Column {
            visible: root.scanSupport.ready
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: parent.width
              Text {
                text: "SCANNER"
                color: root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }

            Text {
              visible: root.scannersLoading
              text: "looking for scanners…"
              color: root.dim
              font.family: root.mono
              font.pixelSize: Style.font.caption
            }

            Column {
              visible: !root.scannersLoading && root.scanners.length === 0
              width: parent.width
              spacing: Style.space(4)
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.scanError !== "" ? root.scanError
                  : "No scanner found on the network or USB."
                color: root.scanError !== "" ? root.urgent : root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
              PcMiniButton { label: "Search again"; onTapped: root.loadScanners() }
            }

            // device picker (only when more than one)
            Flow {
              visible: root.scanners.length > 1
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.scanners
                ScanChip {
                  required property var modelData
                  label: modelData.model || modelData.desc
                  on: root.scanDevice === modelData.id
                  onTapped: root.selectScanner(modelData.id)
                }
              }
            }
            Text {
              visible: root.scanners.length === 1
              width: parent.width
              text: root.scanners.length === 1
                ? ((root.scanners[0].model || root.scanners[0].desc)
                   + (root.scanners[0].kind ? "  " + root.bullet + "  " + root.scanners[0].kind : ""))
                : ""
              color: root.fg
              font.family: root.mono
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // options
            Column {
              visible: root.scanDevice !== "" && !root.scanning
              width: parent.width
              spacing: Style.space(6)

              ScanRow {
                label: "Mode"
                values: root.scanModes
                current: root.scanMode
                onPicked: function (v) { root.scanMode = String(v) }
              }
              ScanRow {
                label: "DPI"
                values: root.scanResolutions
                current: root.scanResolution
                onPicked: function (v) { root.scanResolution = parseInt(v, 10) }
              }
              ScanRow {
                visible: root.scanSources.length > 0
                label: "Source"
                values: root.scanSources
                current: root.scanSource
                onPicked: function (v) { root.scanSource = String(v) }
              }
              ScanRow {
                label: "File"
                values: ["pdf", "png", "jpeg"]
                current: root.scanFormat
                disabledValues: root.scanSupport.pdf ? [] : ["pdf"]
                onPicked: function (v) { root.scanFormat = String(v) }
              }

              PcMiniButton {
                label: root.scanResult ? "Scan again" : "Scan"
                onTapped: root.doScan()
              }
              Text {
                width: parent.width
                text: "saves to " + root.scanDir
                color: Qt.darker(root.dim, 1.1)
                font.family: root.mono
                font.pixelSize: Style.font.caption - 2
              }
            }

            // progress
            Column {
              visible: root.scanning
              width: parent.width
              spacing: Style.space(4)
              Text {
                text: "Scanning" + (root.scanPage > 0 ? " page " + root.scanPage : "")
                  + "…  " + root.scanPct + "%"
                color: root.fg
                font.family: root.mono
                font.pixelSize: Style.font.caption
              }
              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.darker(root.fg, 2.2)
                Rectangle {
                  width: parent.width * Math.max(0, Math.min(100, root.scanPct)) / 100
                  height: parent.height
                  radius: height / 2
                  color: Color.accent
                }
              }
            }

            // result
            Column {
              visible: root.scanResult !== null && !root.scanning
              width: parent.width
              spacing: Style.space(6)
              Image {
                visible: root.scanResult && root.scanResult.format !== "pdf"
                  && root.scanResult.pages && root.scanResult.pages.length > 0
                width: parent.width
                fillMode: Image.PreserveAspectFit
                sourceSize.width: parent.width
                source: (root.scanResult && root.scanResult.pages && root.scanResult.pages.length)
                  ? "file://" + root.scanResult.pages[0] : ""
              }
              Text {
                width: parent.width
                text: (root.scanResult ? root.scanResult.path : "")
                  + (root.scanResult && root.scanResult.pageCount > 1
                     ? "  (" + root.scanResult.pageCount + " pages)" : "")
                color: root.dim
                font.family: root.mono
                font.pixelSize: Style.font.caption - 1
                elide: Text.ElideMiddle
              }
              Row {
                width: parent.width
                spacing: Style.space(6)
                PcMiniButton {
                  label: "Open"
                  onTapped: root.openScan(root.scanResult ? root.scanResult.path : "")
                }
                PcMiniButton { label: "Folder"; onTapped: root.openScanFolder() }
                PcMiniButton {
                  label: "Scan another"
                  onTapped: { root.scanResult = null; root.scanPct = 0; root.scanPage = 0 }
                }
              }
            }

            Text {
              visible: root.scanError !== "" && !root.scanning && root.scanners.length > 0
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.scanError
              color: root.urgent
              font.family: root.mono
              font.pixelSize: Style.font.caption - 1
            }
          }
        }

        // ---- footer -------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(3)

          Text {
            id: settingsLink
            text: "Printer settings " + String.fromCharCode(0x2197)
            color: settingsArea.containsMouse ? Color.accent : root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            MouseArea {
              id: settingsArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSettings()
            }
          }
          Text {
            width: parent.width
            text: "options: ~/.config/omarchy/print-center/config.json"
            color: Qt.darker(root.dim, 1.1)
            font.family: root.mono
            font.pixelSize: Style.font.caption - 2
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // Small pill button used throughout the popup.
  component PcMiniButton: Rectangle {
    property string label: ""
    property bool danger: false
    property bool enabled: true
    signal tapped()
    implicitHeight: Style.space(22)
    implicitWidth: t.implicitWidth + Style.space(16)
    radius: height / 2
    color: ma.containsMouse && enabled
      ? (root.bar ? Style.hoverFillFor(root.fg, danger ? root.urgent : Color.accent) : "#333")
      : "transparent"
    border.width: 1
    border.color: enabled ? (danger ? root.urgent : root.dim) : Qt.darker(root.dim, 1.4)
    opacity: enabled ? 1 : 0.45
    Text {
      id: t
      anchors.centerIn: parent
      text: parent.label
      color: root.fg
      font.family: root.mono
      font.pixelSize: Style.font.caption - 1
    }
    MouseArea {
      id: ma
      anchors.fill: parent
      hoverEnabled: true
      enabled: parent.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.tapped()
    }
  }

  // A single selectable chip (scan mode / dpi / source / format value).
  component ScanChip: Rectangle {
    property string label: ""
    property bool on: false
    property bool enabled: true
    signal tapped()
    implicitHeight: Style.space(22)
    implicitWidth: ct.implicitWidth + Style.space(16)
    radius: height / 2
    color: on ? Style.hoverFillFor(root.fg, Color.accent)
      : (cma.containsMouse && enabled ? Qt.darker(root.fg, 2.4) : "transparent")
    border.width: 1
    border.color: on ? Color.accent : (enabled ? root.dim : Qt.darker(root.dim, 1.5))
    opacity: enabled ? 1 : 0.4
    Text {
      id: ct
      anchors.centerIn: parent
      text: parent.label
      color: parent.on ? Color.accent : root.fg
      font.family: root.mono
      font.pixelSize: Style.font.caption - 1
    }
    MouseArea {
      id: cma
      anchors.fill: parent
      hoverEnabled: true
      enabled: parent.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.tapped()
    }
  }

  // A labelled row of chips: "Mode  [Color] [Gray] [Lineart]".
  component ScanRow: Row {
    id: sr
    property string label: ""
    property var values: []
    property var current: ""
    property var disabledValues: []
    signal picked(var value)
    width: parent ? parent.width : 0
    spacing: Style.space(6)
    Text {
      width: Style.space(44)
      text: sr.label
      color: root.dim
      font.family: root.mono
      font.pixelSize: Style.font.caption - 1
      anchors.verticalCenter: parent.verticalCenter
    }
    Flow {
      width: sr.width - Style.space(52)
      spacing: Style.space(5)
      Repeater {
        model: sr.values
        ScanChip {
          required property var modelData
          label: String(modelData)
          on: String(sr.current) === String(modelData)
          enabled: (sr.disabledValues || []).indexOf(String(modelData)) === -1
          onTapped: sr.picked(modelData)
        }
      }
    }
  }
}

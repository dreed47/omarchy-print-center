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
  ipcTarget: "print-center"
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
  function addPrinter(d) { act(["add", "--uri", String(d.uri), "--name", String(d.queue)]) }

  function refresh() {
    if (svc) svc.poll()
    if (root.showDiscover) root.runDiscover()
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
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.summary
            color: root.sevColor(root.worstState)
            font.family: root.mono
            font.pixelSize: Style.font.caption
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
          visible: !root.cliMissing && root.cupsUp
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
          visible: !root.cliMissing && root.cupsUp
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
          visible: !root.cliMissing && root.cupsUp
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

        // ---- footer -------------------------------------------
        Item {
          width: parent.width
          height: Style.space(24)
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: "Printer settings " + String.fromCharCode(0x2197)
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSettings()
            }
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: "options: ~/.config/omarchy/print-center/config.json"
            color: Qt.darker(root.dim, 1.1)
            font.family: root.mono
            font.pixelSize: Style.font.caption - 2
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
}

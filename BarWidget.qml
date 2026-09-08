import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for Print Center. Shows the tracked printer's state and the queued
// job count; tints accent on a warning and urgent on an error. The popup
// (Panel.qml, loaded lazily) holds the printer list and the queue actions.
// The headless Service.qml owns polling and notifications and publishes the
// numbers this pill reads.
//
// Structure mirrors the MakerWorld / Tempest Weather plugins so the bar's
// popout coordinator, hotkey routing, and popout-switch handoff behave the same.
BarWidget {
  id: root
  moduleName: "io.github.dreed47.print-center"

  readonly property string pluginId: "io.github.dreed47.print-center"
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(pluginId) : null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (svc) svc.refresh()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }
  function notify() {
    if (!root.bar || !panelLoader.item) return
    var lines = panelLoader.item.statusLines()
    if (!lines || lines.length === 0) return
    var headline = lines.shift()
    var body = lines.join("\n")
    var cmd = "omarchy-notification-send --app-name 'Print Center' " + root.bar.shellQuote(headline)
    if (body !== "") cmd += " " + root.bar.shellQuote(body)
    root.bar.run(cmd)
  }

  // Popout contract expected by Bar.findPanelWidget / requestPopout.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  visible: panelLoader.item !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: pillRow.implicitWidth

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  // ---- state from the service --------------------------------
  readonly property bool cliMissing: root.svc ? root.svc.cliMissing === true : false
  readonly property bool cupsUp: root.svc ? root.svc.cupsUp !== false : true
  readonly property int activeJobs: root.svc ? (root.svc.activeJobs || 0) : 0
  readonly property string worstState: root.svc ? String(root.svc.worstState || "ok") : "ok"
  readonly property var tracked: root.svc ? root.svc.trackedCard : null
  readonly property bool showJobCount: (root.svc && root.svc.cfg) ? (root.svc.cfg.showJobCount !== false) : true

  readonly property string alertText: {
    if (cliMissing) return "Node.js missing"
    if (!cupsUp) return "CUPS off"
    if (worstState !== "ok" && tracked && tracked.alerts && tracked.alerts.length)
      return String(tracked.alerts[0].text || "")
    return ""
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : ""
    fixedWidth: pillRow.implicitWidth + Style.spaceReal(17)

    readonly property color accent: root.bar ? Color.accent : "#8ab4f8"
    readonly property color urgent: root.bar ? root.bar.urgent : "#e06c75"
    readonly property color dim: Qt.darker(button.foreground, 1.7)

    readonly property color pillColor: {
      if (root.cliMissing || !root.cupsUp || root.worstState === "error") return button.urgent
      if (root.worstState === "warn") return button.accent
      return button.foreground
    }

    onPressed: function (b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.notify()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.spaceReal(5)

      // Printer glyph (FA ).
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: ""
        color: button.pillColor
        opacity: (root.cliMissing || !root.cupsUp) ? 0.5 : 1
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }

      // Queued job count.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showJobCount && root.activeJobs > 0 && root.cupsUp && !root.cliMissing
        text: String.fromCharCode(0x25cf) + root.activeJobs
        color: button.pillColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }

      // Short alert word ("out of paper", "CUPS off", …).
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.alertText !== ""
        text: root.alertText
        color: button.pillColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }
}

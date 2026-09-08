import QtQuick
import Quickshell
import Quickshell.Io

// Headless half of Print Center: polls `bin/print-center status --json` on a
// timer, publishes the result for the bar pill / popup to read, and raises
// desktop notifications when a job finishes, a job is held, or a printer
// reports an error.
//
// All CUPS access is in the CLI (bin/print-center). This file only spawns it,
// parses its JSON, diffs successive polls, and calls omarchy-notification-send.
//
// Settings: the bar widget's shell.json entry wins; anything unset there falls
// back to ~/.config/omarchy/print-center/config.json, then to built-in
// defaults (see manifest.json barWidget.defaults).
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.dreed47.print-center"

  // ---- paths ------------------------------------------------------
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string cli: pluginDir + "bin/print-center"
  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string confDir: {
    var xdg = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    return (xdg !== "" ? xdg : home + "/.config") + "/omarchy/print-center"
  }
  readonly property string configFile: confDir + "/config.json"

  // ---- config: shell.json entry over config.json over defaults ----
  property var configJsonRaw: ({})
  readonly property var shellEntry: {
    var sc = shell ? shell.shellConfig : null
    if (!sc) return ({})
    try {
      if (sc.bar && sc.bar.layout) {
        var secs = ["left", "center", "right"]
        for (var s = 0; s < secs.length; s++) {
          var arr = sc.bar.layout[secs[s]] || []
          for (var i = 0; i < arr.length; i++)
            if (arr[i] && String(arr[i].id) === root.pluginId) return arr[i]
        }
      }
      var plugs = sc.plugins || []
      for (var j = 0; j < plugs.length; j++)
        if (plugs[j] && String(plugs[j].id) === root.pluginId) return plugs[j]
    } catch (e) {}
    return ({})
  }

  function pick(key, dflt) {
    if (shellEntry && shellEntry[key] !== undefined && shellEntry[key] !== null && shellEntry[key] !== "")
      return shellEntry[key]
    if (configJsonRaw && configJsonRaw[key] !== undefined && configJsonRaw[key] !== null && configJsonRaw[key] !== "")
      return configJsonRaw[key]
    return dflt
  }
  function isOn(v) { return v === true || v === "on" || v === "true" || v === 1 || v === "1" }

  readonly property var cfg: ({
    pollSeconds: Math.max(5, parseInt(pick("pollSeconds", 20), 10) || 20),
    notify: isOn(pick("notify", "on")),
    notifyTypes: String(pick("notifyTypes", "done,error,held")).toLowerCase(),
    notifyTimeoutSeconds: parseInt(pick("notifyTimeoutSeconds", 0), 10) || 0,
    trackedPrinter: String(pick("trackedPrinter", "")),
    showJobCount: isOn(pick("showJobCount", "on")),
    openOnClick: isOn(pick("openOnClick", "off")),
    debug: isOn(pick("debug", "off"))
  })
  function wants(type) {
    var t = cfg.notifyTypes
    return cfg.notify && (t === "all" || t.split(",").map(function (x) { return x.trim() }).indexOf(type) !== -1)
  }

  FileView {
    path: root.configFile
    watchChanges: true
    printErrors: false
    onLoaded: { try { root.configJsonRaw = JSON.parse(text()) || ({}) } catch (e) { root.configJsonRaw = ({}) } }
    onLoadFailed: root.configJsonRaw = ({})
    onFileChanged: reload()
  }

  // ---- live state the pill / popup read -------------------------
  property bool cliMissing: false
  property bool cupsUp: true
  property string defaultPrinter: ""
  property var printers: []
  property var jobs: []
  property var recentCompleted: []
  property int activeJobs: 0
  property string worstState: "ok"     // ok | warn | error
  property string summary: ""
  property double lastPollMs: 0

  // The printer the bar pill focuses on: configured override, else the
  // system default, else the first printer.
  readonly property var trackedCard: {
    var want = cfg.trackedPrinter || defaultPrinter
    for (var i = 0; i < printers.length; i++) {
      if (want && printers[i].name === want) return printers[i]
      if (!want && i === 0) return printers[i]
    }
    return printers.length ? printers[0] : null
  }

  // ---- persisted diff baseline --------------------------------
  PersistentProperties {
    id: st
    reloadableId: "omarchy-print-center"
    property bool baselined: false
    property string activeIdsJson: "[]"       // job ids seen active last poll
    property string heldIdsJson: "[]"         // job ids seen held last poll
    property string printerReasonsJson: "{}"  // { printerName: ["reason", ...] }
  }
  function jparse(s, dflt) { try { var v = JSON.parse(s); return v === null ? dflt : v } catch (e) { return dflt } }

  readonly property int pollMs: Math.max(5, cfg.pollSeconds) * 1000
  property double pollStartedMs: 0

  // ---- poll ---------------------------------------------------
  function poll() {
    if (statusProc.running) {
      // Never let a wedged status call stop polling for good.
      if (Date.now() - root.pollStartedMs < 20000) return
      statusProc.running = false
    }
    root.pollStartedMs = Date.now()
    statusProc.command = ["node", root.cli, "status", "--json"]
    statusProc.running = true
  }

  // One extra poll a moment after an action, since a CUPS change (default set,
  // job cancelled, printer removed) can lag the command that made it.
  Timer {
    id: settleTimer
    interval: 1500
    repeat: false
    onTriggered: root.poll()
  }
  function pollSoon() { Qt.callLater(root.poll); settleTimer.restart() }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var body = String(text || "").trim()
        if (body === "") return
        var s
        try { s = JSON.parse(body) } catch (e) {
          if (root.cfg.debug) console.log("[print-center] status parse error", e)
          return
        }
        root.cliMissing = false
        root.applyStatus(s)
        if (root.cfg.debug)
          console.log("[print-center] poll: printers=" + (s.printers || []).length
            + " default=" + s.defaultPrinter + " jobs=" + (s.jobs || []).length
            + " worst=" + s.worstState)
      }
    }
    onExited: function (code, status) {
      // execFile-style: a missing `node` makes the process fail to start.
      if (code !== 0 && root.printers.length === 0 && !root.cupsUpKnown) {
        // Distinguish "node missing" from "CLI ran and errored": if we never
        // got a parseable status, assume the toolchain isn't there.
        root.cliMissing = true
      }
    }
  }
  property bool cupsUpKnown: false

  function applyStatus(s) {
    root.cupsUpKnown = true
    root.cupsUp = s.cupsUp === true
    root.defaultPrinter = String(s.defaultPrinter || "")
    root.printers = s.printers || []
    root.jobs = s.jobs || []
    root.recentCompleted = s.recentCompleted || []
    root.activeJobs = parseInt(s.activeJobs, 10) || 0
    root.worstState = String(s.worstState || "ok")
    root.summary = String(s.summary || "")
    root.lastPollMs = Date.now()
    root.diffAndNotify()
  }

  // ---- diff successive polls -> notifications ------------------
  function diffAndNotify() {
    var curActive = jobs.filter(function (j) { return j.state !== "held" })
      .map(function (j) { return j.id })
    var curHeld = jobs.filter(function (j) { return j.state === "held" })
      .map(function (j) { return j.id })
    var curReasons = {}
    for (var i = 0; i < printers.length; i++)
      curReasons[printers[i].name] = (printers[i].stateReasons || []).slice()

    if (!st.baselined) {
      st.activeIdsJson = JSON.stringify(curActive)
      st.heldIdsJson = JSON.stringify(curHeld)
      st.printerReasonsJson = JSON.stringify(curReasons)
      st.baselined = true
      return
    }

    var prevActive = jparse(st.activeIdsJson, [])
    var prevHeld = jparse(st.heldIdsJson, [])
    var prevReasons = jparse(st.printerReasonsJson, {})

    // Jobs that were active and are now gone from the queue -> finished.
    if (wants("done")) {
      for (var a = 0; a < prevActive.length; a++) {
        var id = prevActive[a]
        if (curActive.indexOf(id) !== -1) continue
        if (curHeld.indexOf(id) !== -1) continue      // just got held, not done
        var done = null
        for (var c = 0; c < recentCompleted.length; c++)
          if (recentCompleted[c].id === id) { done = recentCompleted[c]; break }
        var title = done && done.title ? done.title : ("job " + (id.split("-").pop()))
        var where = done ? done.printer : ""
        notify("normal", "",
          "Printed" + (where ? " on " + where : ""),
          title, false)
      }
    }

    // Newly held jobs.
    if (wants("held")) {
      for (var h = 0; h < curHeld.length; h++) {
        if (prevHeld.indexOf(curHeld[h]) !== -1) continue
        var hj = null
        for (var k = 0; k < jobs.length; k++) if (jobs[k].id === curHeld[h]) { hj = jobs[k]; break }
        notify("normal", "", "Print job held",
          (hj && hj.title ? hj.title : curHeld[h]) + (hj ? " on " + hj.printer : ""), false)
      }
    }

    // Printers that gained an alert they did not have last poll.
    if (wants("error")) {
      for (var p = 0; p < printers.length; p++) {
        var pr = printers[p]
        var was = prevReasons[pr.name] || []
        var alerts = pr.alerts || []
        for (var x = 0; x < alerts.length; x++) {
          if (was.indexOf(alerts[x].code) !== -1) continue
          notify(alerts[x].severity === "error" ? "critical" : "normal",
            "", "Printer " + pr.name, capitalize(alerts[x].text), true)
        }
      }
    }

    st.activeIdsJson = JSON.stringify(curActive)
    st.heldIdsJson = JSON.stringify(curHeld)
    st.printerReasonsJson = JSON.stringify(curReasons)
  }

  function capitalize(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1) }

  // ---- notification queue -----------------------------------
  property var notifyQueue: []
  function notify(urgency, glyph, headline, body, isError) {
    if (!cfg.notify) return
    var cmd = ["omarchy-notification-send", "--app-name", "Print Center", "-u", urgency]
    if (glyph) { cmd.push("-g"); cmd.push(String(glyph)) }
    if (cfg.notifyTimeoutSeconds > 0) { cmd.push("-t"); cmd.push(String(cfg.notifyTimeoutSeconds * 1000)) }
    cmd.push(String(headline))
    if (body) cmd.push(String(body))
    if (isError && cfg.openOnClick) { cmd.push("--exec"); cmd.push("system-config-printer") }
    notifyQueue.push(cmd)
    pumpNotify()
  }
  Process { id: notifyProc; onExited: root.pumpNotify() }
  function pumpNotify() {
    if (notifyProc.running || notifyQueue.length === 0) return
    notifyProc.command = notifyQueue.shift()
    notifyProc.running = true
  }

  // ---- one-shot actions (called over IPC by the popup) ---------
  Process { id: actionProc; onExited: root.pollSoon() }
  function runAction(args) {
    if (actionProc.running) return
    actionProc.command = ["node", root.cli].concat(args)
    actionProc.running = true
  }

  // ---- timer ------------------------------------------------
  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // ---- IPC --------------------------------------------------
  IpcHandler {
    target: "print-center"
    function refresh(): void { Qt.callLater(root.poll) }
    function rebaseline(): void { st.baselined = false; Qt.callLater(root.poll) }
    function cancel(id: string): void { root.runAction(["cancel", id]) }
    function cancelAll(printer: string): void {
      root.runAction(printer ? ["cancel", "--all", "--printer", printer] : ["cancel", "--all"])
    }
    function hold(id: string): void { root.runAction(["hold", id]) }
    function release(id: string): void { root.runAction(["release", id]) }
    function reprint(id: string): void { root.runAction(["reprint", id]) }
    function makeDefault(name: string): void { root.runAction(["default", name]) }
    function testPage(name: string): void { root.runAction(["testpage", name]) }
    function openSettings(): void { root.runAction(["open-settings"]) }
    function status(): string {
      return JSON.stringify({
        cliMissing: root.cliMissing,
        cupsUp: root.cupsUp,
        defaultPrinter: root.defaultPrinter,
        printers: root.printers,
        jobs: root.jobs,
        recentCompleted: root.recentCompleted,
        activeJobs: root.activeJobs,
        worstState: root.worstState,
        summary: root.summary,
        lastPollMs: root.lastPollMs
      })
    }
  }
}

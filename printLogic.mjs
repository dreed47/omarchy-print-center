// Pure half of Print Center. Every function here takes strings (the raw
// stdout of a CUPS command) or plain data and returns plain data — no child
// processes, no filesystem, no clock beyond Date.parse. The impure side lives
// in lib/io.mjs; the CLI (bin/print-center) glues the two together.
//
// Nothing here is Omarchy- or Quickshell-specific, so it is all unit-testable
// from `node --test`.

// ---- small helpers ------------------------------------------------------

export function fmtBytes(n) {
    n = Number(n) || 0
    if (n < 1024) return n + " B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB"
    return (n / 1024 / 1024).toFixed(n < 10485760 ? 1 : 0) + " MB"
}

export function relTime(ms, now = Date.now()) {
    if (!ms) return ""
    const s = Math.floor((now - ms) / 1000)
    if (s < 0) return "just now"
    if (s < 45) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
}

// CUPS prints dates like "Tue 08 Sep 2026 04:13:57 PM EDT". V8's Date.parse
// handles that as-is; guard anything it cannot read.
export function parseCupsDate(s) {
    if (!s) return 0
    const t = Date.parse(String(s).trim())
    return Number.isFinite(t) ? t : 0
}

// ---- printer discovery on this machine (lpstat) -----------------------

// `lpstat -e` lists every destination you *can* print to, which on Omarchy
// includes transient cups-browsed / driverless auto-queues that appear and
// vanish on their own. For "my printers" we want only real configured queues,
// which is what `lpstat -v` ("device for NAME: uri") reports.
export function parsePrinterNames(lpstatVOut) {
    return parseDeviceList(lpstatVOut).map((d) => d.name)
}

export function parseDeviceList(lpstatVOut) {
    const out = []
    for (const line of String(lpstatVOut || "").split("\n")) {
        const m = line.match(/^device for (.+?):\s*(.+)$/)
        if (m) out.push({ name: m[1].trim(), uri: m[2].trim() })
    }
    return out
}

export function parseDefaultPrinter(lpstatDOut) {
    const m = String(lpstatDOut || "").match(/system default destination:\s*(\S+)/)
    return m ? m[1] : ""
}

// The per-user default from ~/.cups/lpoptions ("Default <name> [options]").
// `Dest` lines are non-default destinations with saved options; ignore them.
export function parseUserDefault(lpoptionsText) {
    const m = String(lpoptionsText || "").match(/^Default\s+(\S+)/m)
    return m ? m[1] : ""
}

// The default the `lp` command would actually use: per-user wins over server.
export function effectiveDefault(lpoptionsText, lpstatDOut) {
    return parseUserDefault(lpoptionsText) || parseDefaultPrinter(lpstatDOut)
}

export function schedulerRunning(lpstatROut) {
    return /scheduler is running/i.test(String(lpstatROut || ""))
}

// One `lpoptions -p NAME` line is a space-separated list of key=value pairs.
// Values may be single-quoted (and then contain spaces), may be empty
// (`printer-location` with nothing after it), and may contain `#`, `,` or `=`.
export function parsePrinterOptions(line) {
    const out = {}
    const s = String(line || "")
    let i = 0
    const n = s.length
    while (i < n) {
        while (i < n && s[i] === " ") i++
        if (i >= n) break
        let key = ""
        while (i < n && s[i] !== "=" && s[i] !== " ") key += s[i++]
        if (i < n && s[i] === " ") { out[key] = ""; continue }      // bare key
        if (i < n && s[i] === "=") i++
        let val = ""
        if (s[i] === "'") {
            i++
            while (i < n && s[i] !== "'") val += s[i++]
            if (i < n) i++
        } else {
            while (i < n && s[i] !== " ") val += s[i++]
        }
        out[key] = val
    }
    return out
}

const PRINTER_STATE_NAMES = { 3: "idle", 4: "processing", 5: "stopped" }

function zipMarkers(opts) {
    const names = (opts["marker-names"] || "").split(",").filter(Boolean)
    if (!names.length) return []
    const types = (opts["marker-types"] || "").split(",")
    const levels = (opts["marker-levels"] || "").split(",")
    const lows = (opts["marker-low-levels"] || "").split(",")
    const highs = (opts["marker-high-levels"] || "").split(",")
    return names.map((nm, k) => ({
        name: nm,
        type: types[k] || "",
        level: numOr(levels[k], -1),
        low: numOr(lows[k], -1),
        high: numOr(highs[k], 100),
    }))
}

// Same shape as zipMarkers, from a direct `ipptool -tv <uri> get-printer-
// attributes.test` dump (used when the CUPS queue itself carries no supply
// data yet - e.g. a just-added queue).
export function parseIpptoolMarkers(ipptoolOut) {
    const grab = (attr) => {
        const m = String(ipptoolOut || "").match(
            new RegExp("^\\s*" + attr + "\\s*\\([^)]*\\)\\s*=\\s*(.+)$", "m"))
        return m ? m[1].trim() : ""
    }
    const names = grab("marker-names").split(",").map((s) => s.trim()).filter(Boolean)
    if (!names.length) return []
    const types = grab("marker-types").split(",")
    const levels = grab("marker-levels").split(",")
    const lows = grab("marker-low-levels").split(",")
    const highs = grab("marker-high-levels").split(",")
    return names.map((nm, k) => ({
        name: nm.replace(/^["']|["']$/g, ""),
        type: (types[k] || "").trim(),
        level: numOr(levels[k], -1),
        low: numOr(lows[k], -1),
        high: numOr(highs[k], 100),
    }))
}
function numOr(v, d) { const n = parseInt(v, 10); return Number.isFinite(n) ? n : d }

// Build the per-printer card the bar pill and popup consume, from the name
// plus the parsed `lpoptions -p NAME` map.
export function printerCard(name, opts, defaultName) {
    opts = opts || {}
    const reasons = (opts["printer-state-reasons"] || "")
        .split(",")
        .map((r) => r.trim())
        .filter((r) => r && r !== "none")
    return {
        name,
        uri: opts["device-uri"] || opts["printer-uri-supported"] || "",
        state: PRINTER_STATE_NAMES[opts["printer-state"]] || "idle",
        stateReasons: reasons,
        accepting: opts["printer-is-accepting-jobs"] === "true",
        shared: opts["printer-is-shared"] === "true",
        isDefault: name === defaultName,
        location: opts["printer-location"] || "",
        info: opts["printer-info"] || "",
        makeAndModel: opts["printer-make-and-model"] || "",
        markers: zipMarkers(opts),
    }
}

// ---- per-printer default options (`lpoptions -p NAME -l`) -----------
//
//   PageSize/Media Size: A4 *Letter Legal Custom.WIDTHxHEIGHT
//   Duplex/Duplex: *None DuplexNoTumble DuplexTumble
// The value prefixed with '*' is the current default. `lpoptions -o KEY=VAL`
// changes it (per-user, unprivileged).

export function parseLpoptionsL(out) {
    const rows = []
    for (const line of String(out || "").split("\n")) {
        const m = line.match(/^([A-Za-z0-9_.-]+)\/(.+?):\s+(.+)$/)
        if (!m) continue
        const values = m[3].trim().split(/\s+/)
        let current = ""
        const clean = values.map((v) => {
            if (v.startsWith("*")) { current = v.slice(1); return v.slice(1) }
            return v
        })
        rows.push({ key: m[1], label: m[2].trim(), values: clean, current })
    }
    return rows
}

// The handful of options worth surfacing, with friendly labels and, where the
// raw list is huge or cryptic, a shortlist. Anything not in this map is hidden.
const OPTION_LABELS = {
    PageSize: "Paper",
    ColorModel: "Color",
    Duplex: "Sides",
    sides: "Sides",
    cupsPrintQuality: "Quality",
    OutputMode: "Quality",
    print_quality: "Quality",
    Resolution: "DPI",
    MediaType: "Type",
    InputSlot: "Tray",
}
const PAGESIZE_SHORTLIST = ["Letter", "Legal", "A4", "A5", "A6", "B5", "Executive", "4x6", "5x7", "Env10", "EnvDL"]
const MEDIATYPE_SHORTLIST = ["Auto", "Stationery", "Plain", "Photographic", "Envelope", "Bond", "Recycled"]
const DUPLEX_DISPLAY = {
    None: "Off", DuplexNoTumble: "Long edge", DuplexTumble: "Short edge",
    "one-sided": "Off", "two-sided-long-edge": "Long edge", "two-sided-short-edge": "Short edge",
}

export function displayOptionValue(key, value) {
    if ((key === "Duplex" || key === "sides") && DUPLEX_DISPLAY[value]) return DUPLEX_DISPLAY[value]
    return String(value).replace(/^Com\.canon/i, "").replace(/^[a-z]+\./i, "")
}

export function shapePrinterOptions(parsed) {
    const out = []
    for (const row of parsed || []) {
        const label = OPTION_LABELS[row.key]
        if (!label) continue
        let values = row.values.filter((v) => !/WIDTHxHEIGHT|Custom\./i.test(v))
        if (row.key === "PageSize") {
            const keep = PAGESIZE_SHORTLIST.filter((v) => values.includes(v))
            if (row.current && !keep.includes(row.current)) keep.unshift(row.current)
            values = keep.length ? keep : values.slice(0, 6)
        } else if (row.key === "MediaType") {
            const keep = values.filter((v) => MEDIATYPE_SHORTLIST.some((s) => v.toLowerCase().includes(s.toLowerCase())))
            if (row.current && !keep.includes(row.current)) keep.unshift(row.current)
            values = keep.length ? keep : (row.current ? [row.current] : values.slice(0, 4))
        } else if (values.length > 6) {
            values = values.slice(0, 6)
            if (row.current && !values.includes(row.current)) values.unshift(row.current)
        }
        out.push({
            key: row.key,
            label,
            current: row.current,
            values: values.map((v) => ({ value: v, display: displayOptionValue(row.key, v) })),
        })
    }
    return out
}

// ---- job queue -------------------------------------------------------

// `lpstat -W <which> -o` lines:  "<job-id>  <user>  <size-bytes>  <date...>"
function parseJobLines(out) {
    const jobs = []
    for (const raw of String(out || "").split("\n")) {
        const line = raw.replace(/\s+$/, "")
        if (!line || /^\s/.test(raw)) continue                 // skip indented -l detail
        const m = line.match(/^(\S+)\s+(\S+)\s+(\d+)\s+(.+)$/)
        if (!m) continue
        const id = m[1]
        const idm = id.match(/-(\d+)$/)
        jobs.push({
            id,
            idNum: idm ? parseInt(idm[1], 10) : 0,
            printer: idm ? id.slice(0, idm.index) : id,
            user: m[2],
            sizeBytes: parseInt(m[3], 10) || 0,
            submittedAt: parseCupsDate(m[4]),
            title: "",
            state: "pending",
        })
    }
    return jobs
}

// `lpstat -l -o` repeats each job line then indents "Alerts: ..." /
// "queued for X". A `job-hold-until` alert means the job is held.
export function heldJobIds(lpstatLongOut) {
    const held = new Set()
    let cur = null
    for (const raw of String(lpstatLongOut || "").split("\n")) {
        if (!/^\s/.test(raw)) {
            const m = raw.match(/^(\S+)\s+\S+\s+\d+\s+/)
            cur = m ? m[1] : null
        } else if (cur && /job-hold-until/.test(raw)) {
            held.add(cur)
        }
    }
    return held
}

// `lpq -a` table:  "Rank  Owner  Job  File(s)  Total Size"
// Rank is "active" for the job being printed, an ordinal otherwise.
export function parseLpq(lpqOut) {
    const rows = []
    for (const line of String(lpqOut || "").split("\n")) {
        const m = line.match(/^(active|\d+\S*)\s+(\S+)\s+(\d+)\s+(.+?)\s{2,}(\d+)\s+bytes\s*$/)
        if (!m) continue
        rows.push({ rank: m[1], owner: m[2], idNum: parseInt(m[3], 10), title: m[4].trim() })
    }
    return rows
}

// Merge the three job views into one list.
export function assembleJobs(lpstatOut, lpstatLongOut, lpqOut) {
    const jobs = parseJobLines(lpstatOut)
    const held = heldJobIds(lpstatLongOut)
    const byNum = new Map()
    for (const r of parseLpq(lpqOut)) byNum.set(r.idNum, r)
    for (const j of jobs) {
        const r = byNum.get(j.idNum)
        if (r) {
            if (r.title && r.title !== "(stdin)") j.title = r.title
            if (r.rank === "active") j.state = "processing"
        }
        if (held.has(j.id)) j.state = "held"
    }
    return jobs
}

export function parseCompletedJobs(lpstatWCompletedOut) {
    return parseJobLines(lpstatWCompletedOut)
        .map((j) => ({ ...j, state: "completed" }))
        .sort((a, b) => b.submittedAt - a.submittedAt)
}

// ---- severity classification ---------------------------------------

const ERROR_REASONS = [
    "media-jam", "media-empty", "media-needed", "toner-empty",
    "marker-supply-empty", "offline", "spool-area-full", "door-open",
    "cover-open", "shutdown", "moving-to-paused",
]
const WARN_REASONS = [
    "media-low", "toner-low", "marker-supply-low", "connecting-to-device",
    "timed-out", "paused", "marker-waste-almost-full", "marker-waste-full",
    "other",
]

export function reasonSeverity(reason) {
    const base = String(reason).replace(/-(report|warning|error)$/, "")
    if (reason.endsWith("-error")) return "error"
    if (ERROR_REASONS.includes(base)) return "error"
    if (reason.endsWith("-warning") || WARN_REASONS.includes(base)) return "warn"
    return "ok"
}

// [{code, text, severity}] for a printer's state-reasons, worst first.
export function printerAlerts(stateReasons) {
    return (stateReasons || [])
        .map((code) => ({ code, text: humanReason(code), severity: reasonSeverity(code) }))
        .filter((a) => a.severity !== "ok")
        .sort((a, b) => (b.severity === "error") - (a.severity === "error"))
}

// Worst of: any printer state-reason + any job that is held or on a stopped
// printer. Returns "ok" | "warn" | "error".
export function worstSeverity(printers, jobs) {
    let sev = "ok"
    const bump = (s) => {
        if (s === "error") sev = "error"
        else if (s === "warn" && sev !== "error") sev = "warn"
    }
    for (const p of printers || []) {
        for (const r of p.stateReasons || []) bump(reasonSeverity(r))
        if (p.state === "stopped") bump("warn")
    }
    for (const j of jobs || []) {
        if (j.state === "held") bump("warn")
    }
    return sev
}

// Short human status for the popup header.
export function summaryLine(printers, jobs, defaultName) {
    const active = (jobs || []).filter((j) => j.state !== "held")
    const held = (jobs || []).filter((j) => j.state === "held")
    const errs = []
    for (const p of printers || []) {
        for (const r of p.stateReasons || []) {
            if (reasonSeverity(r) === "error") errs.push(p.name + ": " + humanReason(r))
        }
    }
    if (errs.length) return errs[0]
    if (active.length === 1) return "1 job printing"
    if (active.length > 1) return active.length + " jobs printing"
    if (held.length) return held.length === 1 ? "1 job held" : held.length + " jobs held"
    if (!(printers || []).length) return "No printers configured"
    const d = (printers || []).find((p) => p.name === defaultName)
    if (d && d.state === "stopped") return d.name + " is paused"
    return "Ready"
}

export function humanReason(reason) {
    const r = String(reason).replace(/-(report|warning|error)$/, "")
    const map = {
        "media-empty": "out of paper",
        "media-low": "paper low",
        "media-jam": "paper jam",
        "media-needed": "load paper",
        "toner-empty": "out of toner",
        "toner-low": "toner low",
        "marker-supply-empty": "out of ink",
        "marker-supply-low": "ink low",
        "marker-waste-full": "waste tank full",
        "marker-waste-almost-full": "waste tank nearly full",
        "cover-open": "cover open",
        "door-open": "door open",
        "offline": "offline",
        "connecting-to-device": "connecting…",
        "timed-out": "not responding",
        "paused": "paused",
    }
    return map[r] || r.replace(/-/g, " ")
}

// ---- network discovery (add-a-printer) ----------------------------

function unescapeAvahi(s) {
    return String(s)
        .replace(/\\(\d{3})/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
        .replace(/\\\./g, ".")
        .replace(/\\\\/g, "\\")
}

// `avahi-browse -rtp _ipp._tcp` resolved rows:
//   =;iface;proto;name;type;domain;host;ip;port;"k=v" "k=v" ...
function parseAvahi(out) {
    const map = new Map()
    for (const line of String(out || "").split("\n")) {
        if (!line.startsWith("=;")) continue
        const f = line.split(";")
        if (f.length < 10) continue
        const name = unescapeAvahi(f[3])
        const proto = f[2]
        const host = f[6]
        const ip = f[7]
        const port = f[8]
        const txt = f.slice(9).join(";")
        const ty = (txt.match(/"ty=([^"]*)"/) || [])[1] || ""
        const rp = (txt.match(/"rp=([^"]*)"/) || [])[1] || "ipp/print"
        const note = (txt.match(/"note=([^"]*)"/) || [])[1] || ""
        const prev = map.get(name)
        // Prefer an IPv4 row for the URI we build.
        if (!prev || (proto === "IPv4" && prev.proto !== "IPv4")) {
            map.set(name, {
                name, proto, model: ty, location: note,
                host, ip, port, rp,
                uri: "ipp://" + (ip || host) + ":" + (port || "631") + "/" + rp.replace(/^\//, ""),
            })
        }
    }
    return map
}

// `driverless` prints one IPP/IPPS URI per line for every driverless queue it
// can see. Those are the authoritative "can be added with -m everywhere" set.
function parseDriverless(out) {
    return String(out || "")
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => /^ipps?:\/\//i.test(l))
}

// Turn a dnssd/ipp URI into a readable printer name + a lpadmin-safe queue id.
export function niceNameFromUri(uri) {
    let s = decodeURIComponent(String(uri || ""))
    const m = s.match(/^ipps?:\/\/([^._/]+(?:\s[^._/]+)*)/i)
    const raw = m ? m[1] : s
    return {
        display: raw.trim(),
        queue: raw.trim().replace(/[^A-Za-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "printer",
    }
}

export function assembleDiscovered(driverlessOut, avahiIppOut, avahiIppsOut) {
    const avahi = new Map([
        ...parseAvahi(avahiIppOut),
        ...parseAvahi(avahiIppsOut),
    ])
    const seen = new Set()
    const list = []
    for (const uri of parseDriverless(driverlessOut)) {
        const nn = niceNameFromUri(uri)
        const key = nn.display.toLowerCase()
        if (seen.has(key)) continue
        seen.add(key)
        const enr = avahi.get(nn.display) || null
        list.push({
            display: nn.display,
            queue: nn.queue,
            // Prefer the resolved ip:port/rp URI (no mDNS lookup needed at
            // print time); fall back to the dnssd/ipp URI `driverless` gave us.
            uri: enr && enr.uri ? enr.uri : uri,
            model: enr ? enr.model : "",
            location: enr ? enr.location : "",
            host: enr ? enr.host : "",
            driverless: true,
        })
    }
    // Avahi-only devices with no driverless entry: still offer them.
    for (const [name, enr] of avahi) {
        if (seen.has(name.toLowerCase())) continue
        seen.add(name.toLowerCase())
        const nn = niceNameFromUri("ipp://" + name)
        list.push({
            display: name, queue: nn.queue, uri: enr.uri,
            model: enr.model, location: enr.location, host: enr.host,
            driverless: false,
        })
    }
    return list
}

// ---- privileged add script (fed to `pkexec sh -c`) ------------------

export function sanitizeQueueName(name) {
    const n = String(name || "").trim()
    if (!n) return null
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(n)) return null
    if (n.length > 127) return null
    return n
}

function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

export function buildAddScript({ name, uri, location, info }) {
    const q = sanitizeQueueName(name)
    if (!q) throw new Error("invalid queue name: " + name)
    if (!/^ipps?:\/\//i.test(String(uri || "")) && !/^dnssd:\/\//i.test(String(uri || "")))
        throw new Error("refusing non-ipp uri: " + uri)
    const parts = [
        "lpadmin", "-p", shq(q), "-E", "-v", shq(uri), "-m", "everywhere",
    ]
    if (info) parts.push("-D", shq(info))
    if (location) parts.push("-L", shq(location))
    return parts.join(" ") + " && cupsenable " + shq(q) + " && cupsaccept " + shq(q)
}

// ---- release / update checking ------------------------------------

// Compare two dotted versions. Returns true when `a` is strictly newer than
// `b`. A trailing pre-release tag ("1.2.0-beta") sorts *before* the plain
// release ("1.2.0").
export function semverGt(a, b) {
    const parse = (v) => {
        const s = String(v || "").trim().replace(/^v/i, "")
        const [core, pre = ""] = s.split("-", 2)
        const nums = core.split(".").map((n) => parseInt(n, 10) || 0)
        while (nums.length < 3) nums.push(0)
        return { nums, pre }
    }
    const x = parse(a), y = parse(b)
    for (let i = 0; i < 3; i++) {
        if (x.nums[i] > y.nums[i]) return true
        if (x.nums[i] < y.nums[i]) return false
    }
    // cores equal: no pre-release beats a pre-release; otherwise lexical
    if (!x.pre && y.pre) return true
    if (x.pre && !y.pre) return false
    return x.pre > y.pre
}

// Shape a GitHub "releases/latest" JSON blob into what the UI needs.
export function parseRelease(json) {
    const j = json || {}
    const tag = String(j.tag_name || "")
    return {
        tag,
        version: tag.replace(/^v/i, ""),
        url: String(j.html_url || ""),
        notes: String(j.body || "").trim().slice(0, 600),
        publishedAt: String(j.published_at || ""),
    }
}

// "https://github.com/owner/repo(.git)" -> "owner/repo"
export function repoSlug(url) {
    const m = String(url || "").match(/github\.com[/:]([^/]+\/[^/.]+)(?:\.git)?/i)
    return m ? m[1] : ""
}

export function buildUpdateInfo(currentVersion, release) {
    const rel = release || {}
    return {
        current: String(currentVersion || ""),
        latest: rel.version || "",
        tag: rel.tag || "",
        url: rel.url || "",
        notes: rel.notes || "",
        updateAvailable: !!rel.version && semverGt(rel.version, currentVersion),
    }
}

// ---- CLI arg parsing ------------------------------------------------

export const COMMANDS = [
    "printers", "jobs", "status", "cancel", "hold", "release",
    "default", "testpage", "reprint", "discover", "open-settings",
    "options", "set-option", "supplies",
    "scan-support", "scanners", "scan-caps", "scan",
    "check-update",
]

const VALUE_FLAGS = new Set([
    "--printer", "--uri", "--name", "--location", "--info", "--option",
    "--device", "--mode", "--resolution", "--source", "--format", "--out",
    "--plugin-dir",
])
const BOOL_FLAGS = new Set([
    "--json", "--completed", "--all", "--adf", "--check", "--install",
])

export function parseArgs(argv) {
    const out = { cmd: "", positionals: [], json: false, completed: false, all: false }
    const rest = argv.slice()
    out.cmd = rest.shift() || ""
    if (out.cmd === "-h" || out.cmd === "--help") { out.help = true; out.cmd = "" }
    for (let i = 0; i < rest.length; i++) {
        const a = rest[i]
        if (a === "-h" || a === "--help") out.help = true
        else if (BOOL_FLAGS.has(a)) out[a.slice(2)] = true
        else if (VALUE_FLAGS.has(a)) out[a.slice(2)] = rest[++i]
        else if (a.startsWith("--")) throw new Error("unknown option: " + a)
        else out.positionals.push(a)
    }
    return out
}

export const HELP = `print-center - manage CUPS printers and the print queue

usage:
  print-center status   [--json]              overview: printers, queue, health
  print-center printers  [--json]             configured printers + ink levels
  print-center jobs      [--json] [--completed] [--printer NAME]
  print-center cancel    <job-id | --all [--printer NAME]>
  print-center hold      <job-id>
  print-center release   <job-id>
  print-center default   <printer>            set your default (per-user)
  print-center testpage  <printer>            print a CUPS test page
  print-center reprint   <job-id>             restart a retained completed job
  print-center discover  [--json]             printers on the network to add
  print-center add       --uri <ipp://…> --name <queue> [--location L]
  print-center open-settings                  launch system-config-printer

  print-center options   --printer NAME [--json]   default paper/duplex/…
  print-center set-option --printer NAME --option KEY=VALUE
  print-center supplies  --printer NAME [--json]    live ink/toner levels

  print-center check-update [--json]          is a newer release out?

  print-center scan-support [--json]          are SANE + img2pdf installed?
  print-center scanners  [--json]             scanners on the network / USB
  print-center scan-caps --device <id> [--json]
  print-center scan      --device <id> [--mode M] [--resolution DPI]
                         [--source S | --adf] [--format pdf|png|jpeg] [--out DIR]

Only 'add' needs elevation (pkexec lpadmin); everything else runs as you.
Scanning needs the sane, sane-airscan and img2pdf packages.
`

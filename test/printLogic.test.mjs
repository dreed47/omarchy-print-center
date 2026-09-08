import { test } from "node:test"
import assert from "node:assert/strict"

import {
    fmtBytes, relTime, parseCupsDate,
    parsePrinterNames, parseDeviceList, parseDefaultPrinter, parseUserDefault, effectiveDefault, schedulerRunning,
    parsePrinterOptions, printerCard,
    heldJobIds, parseLpq, assembleJobs, parseCompletedJobs,
    worstSeverity, summaryLine, humanReason,
    assembleDiscovered, niceNameFromUri, buildAddScript, sanitizeQueueName,
    parseArgs,
} from "../printLogic.mjs"

// Real output captured from a CUPS 2.4.19 box with one driverless Canon.
const LPSTAT_V =
    "device for Canon-G4080-series: ipp://192.168.86.99:631/ipp/print\n" +
    "device for Office-HP: dnssd://HP%20LaserJet._ipp._tcp.local/\n"
const LPSTAT_D = "system default destination: Canon-G4080-series\n"
const LPOPTIONS_CANON =
    "copies=1 device-uri=dnssd://Canon%20G4080%20series._ipps._tcp.local/?uuid=00000000-0000-1000-8000-00114b502dd9 " +
    "finishings=3 job-cancel-after=10800 job-hold-until=no-hold job-priority=50 job-sheets=none,none " +
    "marker-change-time=1788450860 marker-colors=#000000,#00CFFF,#F200FF,#FFDA00,#008080 " +
    "marker-high-levels=100,100,100,100,64 marker-levels=90,90,90,90,10 marker-low-levels=15,15,15,15,0 " +
    "marker-names=Black(PGBK),Cyan,Magenta,Yellow,MC marker-types=ink-cartridge,ink-cartridge,ink-cartridge,ink-cartridge,waste-ink " +
    "number-up=1 print-color-mode=color printer-commands=none printer-info='Canon G4080 series' " +
    "printer-is-accepting-jobs=true printer-is-shared=true printer-is-temporary=false printer-location " +
    "printer-make-and-model='Canon Printer, driverless, 2.1.1' printer-state=3 printer-state-change-time=1788450929 " +
    "printer-state-reasons=none printer-type=167964 printer-uri-supported=ipp://localhost/printers/Canon-G4080-series"

const JOBS_PLAIN =
    "Canon-G4080-series-4    david             1024   Tue 08 Sep 2026 04:13:57 PM EDT\n" +
    "Canon-G4080-series-7    david          2587648   Tue 08 Sep 2026 04:20:01 PM EDT\n"
const JOBS_LONG =
    "Canon-G4080-series-4    david             1024   Tue 08 Sep 2026 04:13:57 PM EDT\n" +
    "\tAlerts: job-hold-until-specified\n" +
    "\tqueued for Canon-G4080-series\n" +
    "Canon-G4080-series-7    david          2587648   Tue 08 Sep 2026 04:20:01 PM EDT\n" +
    "\tqueued for Canon-G4080-series\n"
const LPQ_A =
    "Rank    Owner   Job     File(s)                         Total Size\n" +
    "active  david   7       Quarterly report.pdf            2587648 bytes\n" +
    "1st     david   4       testprint                       1024 bytes\n"

test("fmtBytes", () => {
    assert.equal(fmtBytes(512), "512 B")
    assert.equal(fmtBytes(2048), "2.0 KB")
    assert.equal(fmtBytes(5 * 1024 * 1024), "5.0 MB")
})

test("relTime buckets", () => {
    const now = 10_000_000_000
    assert.equal(relTime(now - 10_000, now), "just now")
    assert.equal(relTime(now - 120_000, now), "2m ago")
    assert.equal(relTime(now - 7_200_000, now), "2h ago")
    assert.equal(relTime(now - 2 * 86_400_000, now), "2d ago")
    assert.equal(relTime(0, now), "")
})

test("parseCupsDate reads the weekday-first format", () => {
    const ms = parseCupsDate("Tue 08 Sep 2026 04:13:57 PM EDT")
    assert.equal(new Date(ms).toISOString(), "2026-09-08T20:13:57.000Z")
    assert.equal(parseCupsDate("garbage"), 0)
    assert.equal(parseCupsDate(""), 0)
})

test("parseDeviceList / parsePrinterNames read real queues from lpstat -v", () => {
    assert.deepEqual(parseDeviceList(LPSTAT_V), [
        { name: "Canon-G4080-series", uri: "ipp://192.168.86.99:631/ipp/print" },
        { name: "Office-HP", uri: "dnssd://HP%20LaserJet._ipp._tcp.local/" },
    ])
    assert.deepEqual(parsePrinterNames(LPSTAT_V), ["Canon-G4080-series", "Office-HP"])
    assert.deepEqual(parsePrinterNames(""), [])
})

test("parseDefaultPrinter / schedulerRunning", () => {
    assert.equal(parseDefaultPrinter(LPSTAT_D), "Canon-G4080-series")
    assert.equal(parseDefaultPrinter("no system default destination"), "")
    assert.equal(schedulerRunning("scheduler is running"), true)
    assert.equal(schedulerRunning("scheduler is not running"), false)
})

test("parseUserDefault / effectiveDefault: per-user default wins over server", () => {
    const lpopts = "Dest Office-HP media=a4\nDefault Canon-G4080-series ColorModel=Gray\n"
    assert.equal(parseUserDefault(lpopts), "Canon-G4080-series")
    assert.equal(parseUserDefault("Dest Office-HP media=a4\n"), "")   // no Default line
    assert.equal(parseUserDefault(""), "")
    // per-user overrides the server default
    assert.equal(effectiveDefault(lpopts, "system default destination: Office-HP"), "Canon-G4080-series")
    // falls back to the server default when no per-user default is set
    assert.equal(effectiveDefault("", "system default destination: Office-HP"), "Office-HP")
    assert.equal(effectiveDefault("", "no system default destination"), "")
})

test("parsePrinterOptions handles quotes, empty keys, hashes, commas", () => {
    const o = parsePrinterOptions(LPOPTIONS_CANON)
    assert.equal(o["printer-info"], "Canon G4080 series")
    assert.equal(o["printer-make-and-model"], "Canon Printer, driverless, 2.1.1")
    assert.equal(o["printer-location"], "")
    assert.equal(o["printer-state"], "3")
    assert.equal(o["marker-levels"], "90,90,90,90,10")
    assert.equal(o["marker-colors"], "#000000,#00CFFF,#F200FF,#FFDA00,#008080")
})

test("printerCard shape + markers zipped", () => {
    const c = printerCard("Canon-G4080-series", parsePrinterOptions(LPOPTIONS_CANON), "Canon-G4080-series")
    assert.equal(c.state, "idle")
    assert.equal(c.isDefault, true)
    assert.equal(c.accepting, true)
    assert.deepEqual(c.stateReasons, [])
    assert.equal(c.makeAndModel, "Canon Printer, driverless, 2.1.1")
    assert.equal(c.markers.length, 5)
    assert.deepEqual(c.markers[0], { name: "Black(PGBK)", type: "ink-cartridge", level: 90, low: 15, high: 100 })
    assert.equal(c.markers[4].name, "MC")
    assert.equal(c.markers[4].level, 10)
})

test("printerCard filters 'none' reasons and reads real reasons", () => {
    const o = parsePrinterOptions("printer-state=5 printer-state-reasons=media-empty-warning,toner-low-report")
    const c = printerCard("X", o, "")
    assert.equal(c.state, "stopped")
    assert.deepEqual(c.stateReasons, ["media-empty-warning", "toner-low-report"])
})

test("heldJobIds picks the held job only", () => {
    assert.deepEqual([...heldJobIds(JOBS_LONG)], ["Canon-G4080-series-4"])
})

test("parseLpq maps id -> title and marks active", () => {
    const rows = parseLpq(LPQ_A)
    assert.equal(rows.length, 2)
    const active = rows.find((r) => r.rank === "active")
    assert.equal(active.idNum, 7)
    assert.equal(active.title, "Quarterly report.pdf")
})

test("assembleJobs merges the three views", () => {
    const jobs = assembleJobs(JOBS_PLAIN, JOBS_LONG, LPQ_A)
    assert.equal(jobs.length, 2)
    const j4 = jobs.find((j) => j.idNum === 4)
    const j7 = jobs.find((j) => j.idNum === 7)
    assert.equal(j4.state, "held")
    assert.equal(j4.title, "testprint")
    assert.equal(j4.printer, "Canon-G4080-series")
    assert.equal(j7.state, "processing")
    assert.equal(j7.title, "Quarterly report.pdf")
    assert.equal(j7.sizeBytes, 2587648)
})

test("parseCompletedJobs newest first", () => {
    const done = parseCompletedJobs(
        "P-1  david  10  Thu 03 Sep 2026 11:54:00 AM EDT\n" +
        "P-2  david  20  Thu 03 Sep 2026 11:55:29 AM EDT\n")
    assert.equal(done[0].idNum, 2)
    assert.equal(done[0].state, "completed")
})

test("worstSeverity", () => {
    assert.equal(worstSeverity([{ stateReasons: [], state: "idle" }], []), "ok")
    assert.equal(worstSeverity([{ stateReasons: ["toner-low"], state: "idle" }], []), "warn")
    assert.equal(worstSeverity([{ stateReasons: ["media-jam"], state: "stopped" }], []), "error")
    assert.equal(worstSeverity([{ stateReasons: [], state: "idle" }], [{ state: "held" }]), "warn")
    assert.equal(worstSeverity([{ stateReasons: ["cups-something-error"], state: "idle" }], []), "error")
})

test("summaryLine phrasing", () => {
    assert.equal(summaryLine([], [], ""), "No printers configured")
    assert.equal(summaryLine([{ name: "A", state: "idle", stateReasons: [] }], [], "A"), "Ready")
    assert.equal(summaryLine([{ name: "A", state: "idle", stateReasons: [] }],
        [{ state: "processing" }, { state: "processing" }], "A"), "2 jobs printing")
    assert.equal(summaryLine([{ name: "A", state: "idle", stateReasons: [] }],
        [{ state: "held" }], "A"), "1 job held")
    assert.equal(summaryLine([{ name: "A", state: "idle", stateReasons: ["media-empty"] }], [], "A"),
        "A: out of paper")
    assert.equal(summaryLine([{ name: "A", state: "stopped", stateReasons: [] }], [], "A"), "A is paused")
})

test("humanReason", () => {
    assert.equal(humanReason("media-empty"), "out of paper")
    assert.equal(humanReason("marker-supply-low-warning"), "ink low")
    assert.equal(humanReason("some-unknown-thing"), "some unknown thing")
})

test("niceNameFromUri", () => {
    assert.deepEqual(
        niceNameFromUri("ipps://Canon%20G4080%20series._ipps._tcp.local/"),
        { display: "Canon G4080 series", queue: "Canon-G4080-series" })
})

test("assembleDiscovered merges driverless + avahi, dedups", () => {
    const driverless = "ipps://Canon%20G4080%20series._ipps._tcp.local/\n"
    const avahi =
        '=;wlp2s0;IPv4;Canon\\032G4080\\032series;Internet Printer;local;host.local;192.168.86.99;631;' +
        '"rp=ipp/print" "ty=Canon G4080 series" "note=Front desk"\n'
    const list = assembleDiscovered(driverless, avahi, "")
    assert.equal(list.length, 1)
    assert.equal(list[0].display, "Canon G4080 series")
    assert.equal(list[0].queue, "Canon-G4080-series")
    assert.equal(list[0].uri, "ipp://192.168.86.99:631/ipp/print")
    assert.equal(list[0].model, "Canon G4080 series")
    assert.equal(list[0].location, "Front desk")
    assert.equal(list[0].driverless, true)
})

test("sanitizeQueueName", () => {
    assert.equal(sanitizeQueueName("Canon-G4080_series.2"), "Canon-G4080_series.2")
    assert.equal(sanitizeQueueName("bad name"), null)
    assert.equal(sanitizeQueueName("bad/slash"), null)
    assert.equal(sanitizeQueueName(""), null)
    assert.equal(sanitizeQueueName(".hidden"), null)
})

test("buildAddScript quotes and refuses non-ipp", () => {
    const s = buildAddScript({ name: "Lobby", uri: "ipp://10.0.0.5:631/ipp/print", location: "Lobby 1" })
    assert.match(s, /^lpadmin -p 'Lobby' -E -v 'ipp:\/\/10\.0\.0\.5:631\/ipp\/print' -m everywhere/)
    assert.match(s, /cupsenable 'Lobby' && cupsaccept 'Lobby'$/)
    assert.throws(() => buildAddScript({ name: "X", uri: "http://evil/x" }), /non-ipp/)
    assert.throws(() => buildAddScript({ name: "bad name", uri: "ipp://h/p" }), /invalid queue name/)
})

test("parseArgs", () => {
    assert.deepEqual(parseArgs(["status", "--json"]), {
        cmd: "status", positionals: [], json: true, completed: false, all: false,
    })
    const a = parseArgs(["add", "--uri", "ipp://h/p", "--name", "Q", "--location", "Desk 2", "--info", "Front Canon"])
    assert.equal(a.cmd, "add"); assert.equal(a.uri, "ipp://h/p")
    assert.equal(a.name, "Q"); assert.equal(a.location, "Desk 2"); assert.equal(a.info, "Front Canon")
    assert.deepEqual(parseArgs(["jobs", "--completed", "--printer", "A"]).printer, "A")
    assert.throws(() => parseArgs(["status", "--bogus"]), /unknown option/)
    assert.equal(parseArgs(["--help"]).help, true)
    assert.equal(parseArgs(["-h"]).help, true)
    assert.equal(parseArgs([]).cmd, "")
})

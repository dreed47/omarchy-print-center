import { test } from "node:test"
import assert from "node:assert/strict"

import {
    parseScanners, parseScanCaps, sourceIsAdf,
    buildScanArgs, parseProgress, scanBaseName, expandHome,
    normalizeFormat, formatExt, scanimageRasterFormat, scanSupport,
} from "../scanLogic.mjs"

// ---- scanimage -L ------------------------------------------------

test("parseScanners: eSCL airscan device", () => {
    const out =
        "device `airscan:e0:Canon G4080 series' is a eSCL Canon G4080 series flatbed scanner\n"
    const [d] = parseScanners(out)
    assert.equal(d.id, "airscan:e0:Canon G4080 series")
    assert.equal(d.desc, "eSCL Canon G4080 series flatbed")
    assert.equal(d.vendor, "Canon")
    assert.equal(d.model, "Canon G4080 series")
    assert.equal(d.kind, "flatbed")
    assert.equal(d.transport, "airscan")
})

test("parseScanners: ADF device + multiple + blank lines", () => {
    const out = [
        "",
        "device `escl:https://192.168.1.9:443' is a eSCL HP OfficeJet Pro ADF scanner",
        "device `airscan:w1:Brother MFC' is a WSD Brother MFC sheetfed scanner",
        "",
    ].join("\n")
    const list = parseScanners(out)
    assert.equal(list.length, 2)
    assert.equal(list[0].kind, "ADF")
    assert.equal(list[0].vendor, "HP")
    assert.equal(list[1].transport, "airscan")
    assert.equal(list[1].vendor, "Brother")
})

test("parseScanners: nothing", () => {
    assert.deepEqual(parseScanners("\nNo scanners were identified.\n"), [])
})

// ---- scanimage -A ----------------------------------------------

const CAPS_OUT = `
Options specific to device \`airscan:e0:Canon G4080 series':
  Scan mode:
    --mode Color|Gray|Lineart [Color]
        Selects the scan mode.
    --resolution 75|100|150|200|300|400|600|1200dpi [300]
        Sets the resolution of the scanned image.
  Geometry:
    -l 0..216.07mm [0]
    -t 0..297mm [0]
    --source Flatbed|ADF|ADF Duplex [Flatbed]
        Selects the scan source.
`

test("parseScanCaps: enum options + defaults", () => {
    const c = parseScanCaps(CAPS_OUT)
    assert.deepEqual(c.modes, ["Color", "Gray", "Lineart"])
    assert.deepEqual(c.resolutions, [75, 100, 150, 200, 300, 400, 600, 1200])
    assert.deepEqual(c.sources, ["Flatbed", "ADF", "ADF Duplex"])
    assert.equal(c.defaults.mode, "Color")
    assert.equal(c.defaults.resolution, 300)
    assert.equal(c.defaults.source, "Flatbed")
})

test("parseScanCaps: resolution range form", () => {
    const c = parseScanCaps("    --resolution 75..1200dpi (in steps of 1) [200]\n")
    assert.ok(c.resolutions.includes(300) && c.resolutions.includes(600))
    assert.ok(!c.resolutions.includes(50))
    assert.equal(c.defaults.resolution, 200)
})

test("parseScanCaps: no options -> safe fallbacks", () => {
    const c = parseScanCaps("")
    assert.deepEqual(c.modes, ["Color", "Gray"])
    assert.deepEqual(c.resolutions, [150, 300, 600])
    assert.equal(c.defaults.mode, "Color")
    assert.equal(c.defaults.resolution, 300)
    assert.deepEqual(c.sources, [])
})

test("sourceIsAdf", () => {
    assert.equal(sourceIsAdf("ADF Duplex"), true)
    assert.equal(sourceIsAdf("Automatic Document Feeder"), true)
    assert.equal(sourceIsAdf("Flatbed"), false)
    assert.equal(sourceIsAdf(""), false)
})

// ---- formats -------------------------------------------------

test("format helpers", () => {
    assert.equal(normalizeFormat("PDF"), "pdf")
    assert.equal(normalizeFormat("jpg"), "jpeg")
    assert.equal(normalizeFormat("weird"), "pdf")
    assert.equal(formatExt("jpeg"), "jpg")
    assert.equal(formatExt("pdf"), "pdf")
    assert.equal(scanimageRasterFormat("pdf"), "png")
    assert.equal(scanimageRasterFormat("jpeg"), "jpeg")
    assert.equal(scanimageRasterFormat("png"), "png")
})

// ---- argv ---------------------------------------------------

test("buildScanArgs: single page", () => {
    const a = buildScanArgs({
        device: "airscan:e0:X", mode: "Gray", resolution: 300,
        source: "Flatbed", rasterFormat: "png", outPath: "/tmp/out.png",
    })
    assert.deepEqual(a, [
        "-d", "airscan:e0:X", "--format=png", "--progress",
        "--mode", "Gray", "--resolution", "300", "--source", "Flatbed",
        "-o", "/tmp/out.png",
    ])
})

test("buildScanArgs: batch pattern instead of -o", () => {
    const a = buildScanArgs({
        device: "d", resolution: 600, rasterFormat: "jpeg",
        batchPattern: "/tmp/x/p%03d.jpg",
    })
    assert.ok(a.includes("--batch=/tmp/x/p%03d.jpg"))
    assert.ok(!a.includes("-o"))
    assert.deepEqual(a.slice(0, 4), ["-d", "d", "--format=jpeg", "--progress"])
})

test("buildScanArgs: device required", () => {
    assert.throws(() => buildScanArgs({}), /device is required/)
})

// ---- progress ---------------------------------------------

test("parseProgress: last percentage wins + page number", () => {
    assert.deepEqual(parseProgress("Progress: 12.5%\nProgress: 47.9%\n"), { pct: 47.9, page: null })
    assert.deepEqual(parseProgress("Scanning page 2\nProgress: 3.0%"), { pct: 3, page: 2 })
    assert.deepEqual(parseProgress("Scanned page 1."), { pct: null, page: 1 })
    assert.deepEqual(parseProgress("nothing here"), { pct: null, page: null })
})

// ---- misc -------------------------------------------------

test("scanBaseName format", () => {
    const n = scanBaseName(new Date("2026-09-08T16:07:03"))
    assert.equal(n, "scan-20260908-160703")
})

test("expandHome", () => {
    assert.equal(expandHome("~", "/home/d"), "/home/d")
    assert.equal(expandHome("~/Pictures/Scans", "/home/d"), "/home/d/Pictures/Scans")
    assert.equal(expandHome("/abs/path", "/home/d"), "/abs/path")
    assert.equal(expandHome("", "/home/d"), "/home/d/Pictures/Scans")
})

test("scanSupport", () => {
    assert.deepEqual(
        scanSupport({ hasScanimage: true, hasImg2pdf: false, missingPkgs: ["img2pdf"] }),
        { scanimage: true, img2pdf: false, ready: true, pdf: false, missing: ["img2pdf"] })
    assert.deepEqual(
        scanSupport({ hasScanimage: false, hasImg2pdf: false, missingPkgs: ["sane", "sane-airscan", "img2pdf"] }),
        { scanimage: false, img2pdf: false, ready: false, pdf: false, missing: ["sane", "sane-airscan", "img2pdf"] })
})

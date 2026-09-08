// Pure half of the scanning feature. Parses `scanimage -L` / `scanimage -A`
// output and builds scanimage argv; no child processes or filesystem here.
// Impure calls live in lib/io.mjs, the CLI wires them together.
//
// Formats below are from SANE 1.x (`sane-airscan` eSCL backend on the dev
// box). Adjust the regexes if a real scanner prints something different.

// ---- `scanimage -L` --------------------------------------------------
//
//   device `airscan:e0:Canon G4080 series' is a eSCL Canon G4080 series flatbed scanner
//   device `escl:https://192.168.1.9:443' is a eSCL HP OfficeJet ... scanner

export function parseScanners(scanimageLOut) {
    const list = []
    for (const line of String(scanimageLOut || "").split("\n")) {
        const m = line.match(/^device `([^']+)' is a (.+?)\s*$/)
        if (!m) continue
        const id = m[1].trim()
        const desc = m[2].replace(/\s+scanner$/i, "").trim()
        list.push({ id, desc, ...describeScanner(id, desc) })
    }
    return list
}

function describeScanner(id, desc) {
    const words = desc.split(/\s+/)
    // drop a leading backend/protocol token like "eSCL" / "WSD"
    if (/^(escl|wsd)$/i.test(words[0])) words.shift()
    const kind = /adf|duplex/i.test(desc) ? "ADF"
        : /flatbed/i.test(desc) ? "flatbed" : ""
    const clean = words.join(" ").replace(/\s*(flatbed|adf|sheetfed|duplex)\s*/ig, " ").trim()
    return {
        vendor: words[0] || "",
        model: clean || desc,
        kind,
        transport: id.split(":")[0] || "",
    }
}

// ---- `scanimage -A -d <dev>` --------------------------------------
//
//   --mode Color|Gray|Lineart [Color]
//   --resolution 75|100|150|300|600|1200dpi [300]
//   --resolution 75..1200dpi (in steps of 1) [300]
//   --source Flatbed|ADF|ADF Duplex [Flatbed]

function optLine(out, name) {
    const re = new RegExp("^\\s*--" + name + "\\s+(.+?)\\s*(?:\\[([^\\]]*)\\])?\\s*$", "m")
    return String(out || "").match(re)
}

function enumValues(spec) {
    const s = String(spec || "").trim()
    // range form: "75..1200dpi (in steps of 1)"
    const range = s.match(/^(\d+)\s*\.\.\s*(\d+)/)
    if (range) {
        const lo = parseInt(range[1], 10), hi = parseInt(range[2], 10)
        return [lo, 150, 200, 300, 400, 600, 1200].filter((n) => n >= lo && n <= hi)
    }
    // pipe list: "Color|Gray|Lineart" or "75|150|300dpi"
    return s.replace(/\s*\(.*?\)\s*/g, "")
        .split("|")
        .map((v) => v.replace(/dpi$/i, "").trim())
        .filter(Boolean)
        .map((v) => (/^\d+$/.test(v) ? parseInt(v, 10) : v))
}

export function parseScanCaps(scanimageAOut) {
    const out = { modes: [], resolutions: [], sources: [], defaults: {} }

    const m = optLine(scanimageAOut, "mode")
    if (m) { out.modes = enumValues(m[1]); if (m[2]) out.defaults.mode = m[2].trim() }

    const r = optLine(scanimageAOut, "resolution")
    if (r) {
        out.resolutions = enumValues(r[1]).map((n) => parseInt(n, 10)).filter(Boolean)
        if (r[2]) out.defaults.resolution = parseInt(r[2], 10) || undefined
    }

    const s = optLine(scanimageAOut, "source")
    if (s) { out.sources = enumValues(s[1]).map(String); if (s[2]) out.defaults.source = s[2].trim() }

    // Sensible fallbacks when a scanner does not advertise an option.
    if (!out.modes.length) out.modes = ["Color", "Gray"]
    if (!out.resolutions.length) out.resolutions = [150, 300, 600]
    if (!out.defaults.mode) out.defaults.mode = out.modes.includes("Color") ? "Color" : String(out.modes[0])
    if (!out.defaults.resolution) out.defaults.resolution = out.resolutions.includes(300) ? 300 : out.resolutions[0]
    if (out.sources.length && !out.defaults.source) out.defaults.source = out.sources[0]
    return out
}

export function sourceIsAdf(source) {
    return /adf|feeder|duplex/i.test(String(source || ""))
}

// ---- filenames / formats --------------------------------------

const FORMAT_EXT = { pdf: "pdf", png: "png", jpeg: "jpg", jpg: "jpg", tiff: "tiff" }

export function normalizeFormat(fmt) {
    const f = String(fmt || "pdf").toLowerCase()
    return FORMAT_EXT[f] ? (f === "jpg" ? "jpeg" : f) : "pdf"
}
export function formatExt(fmt) { return FORMAT_EXT[normalizeFormat(fmt)] || "pdf" }

// scanimage's own --format flag only understands raster types.
export function scanimageRasterFormat(fmt) {
    const f = normalizeFormat(fmt)
    return f === "pdf" ? "png" : (f === "jpg" ? "jpeg" : f)
}

export function scanBaseName(now = new Date()) {
    const p = (n) => String(n).padStart(2, "0")
    return "scan-" + now.getFullYear() + p(now.getMonth() + 1) + p(now.getDate())
        + "-" + p(now.getHours()) + p(now.getMinutes()) + p(now.getSeconds())
}

export function expandHome(dir, home) {
    const d = String(dir || "")
    if (d === "~") return home
    if (d.startsWith("~/")) return home + d.slice(1)
    return d || (home + "/Pictures/Scans")
}

// ---- scanimage argv ---------------------------------------------

// Single page -> one file at `outPath`. ADF/batch -> `batchPattern` (a
// printf template scanimage fills, e.g. ".../scan-...-p%02d.png").
export function buildScanArgs({ device, mode, resolution, source, rasterFormat, outPath, batchPattern }) {
    if (!device) throw new Error("buildScanArgs: device is required")
    const a = ["-d", device, "--format=" + (rasterFormat || "png"), "--progress"]
    if (mode) a.push("--mode", String(mode))
    if (resolution) a.push("--resolution", String(parseInt(resolution, 10) || 300))
    if (source) a.push("--source", String(source))
    if (batchPattern) a.push("--batch=" + batchPattern)
    else a.push("-o", outPath)
    return a
}

// scanimage --progress writes "Progress: 42.7%" to stderr, plus
// "Scanning page N" / "Scanned page N." during a batch.
export function parseProgress(text) {
    const s = String(text || "")
    let pct = null
    const all = s.match(/Progress:\s*([\d.]+)%/g)
    if (all && all.length) pct = parseFloat(all[all.length - 1].match(/([\d.]+)/)[1])
    const pageM = s.match(/Sca?n(?:ning|ned) page (\d+)/i)
    const page = pageM ? parseInt(pageM[1], 10) : null
    return { pct, page }
}

// ---- dependency check ------------------------------------------

export const SCAN_PACKAGES = ["sane", "sane-airscan", "img2pdf"]

export function scanSupport({ hasScanimage, hasImg2pdf, missingPkgs }) {
    return {
        scanimage: !!hasScanimage,
        img2pdf: !!hasImg2pdf,
        ready: !!hasScanimage,             // PNG/JPEG work without img2pdf
        pdf: !!hasScanimage && !!hasImg2pdf,
        missing: missingPkgs || [],
    }
}

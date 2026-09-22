// Impure side of Print Center: everything that shells out to CUPS / Avahi /
// polkit. Kept apart from printLogic.mjs so the parsers there stay pure.
//
// `run` never rejects on a non-zero exit — callers inspect `code` — and every
// call carries a timeout so a wedged lpstat (network printer asleep) cannot
// park the caller forever.

import { execFile, spawn } from "node:child_process"
import { readFileSync, mkdirSync, readdirSync, rmSync, renameSync, copyFileSync, unlinkSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

export function run(cmd, args, opts = {}) {
    return new Promise((resolve, reject) => {
        execFile(
            cmd,
            args,
            { maxBuffer: 16 * 1024 * 1024, encoding: "utf8", timeout: 15000, killSignal: "SIGKILL", ...opts },
            (err, stdout, stderr) => {
                if (err && err.code === "ENOENT") { reject(new Error(cmd + ": command not found")); return }
                resolve({
                    code: err && typeof err.code === "number" ? err.code : err ? 1 : 0,
                    stdout: stdout || "",
                    stderr: stderr || "",
                })
            }
        )
    })
}

export async function hasCommand(name) {
    try {
        const { code } = await run("sh", ["-c", 'command -v "$1" >/dev/null 2>&1', "sh", name])
        return code === 0
    } catch {
        return false
    }
}

// Best-effort stdout of a command; "" if it is missing or fails.
async function out(cmd, args, opts) {
    try {
        const { stdout } = await run(cmd, args, opts)
        return stdout
    } catch {
        return ""
    }
}

// ---- read-only CUPS queries --------------------------------------

export const lpstatR = () => out("lpstat", ["-r"])
// `-v` = real configured queues only ("device for NAME: uri"). `-e` also
// includes transient auto-discovered queues, which we deliberately skip.
export const lpstatV = () => out("lpstat", ["-v"])
export const lpstatE = () => out("lpstat", ["-e"])
export const lpstatD = () => out("lpstat", ["-d"])

// `lpstat -d` reports the *server* default and ignores the per-user default
// that `lpoptions -d` writes to ~/.cups/lpoptions. Read that file so "Set
// default" (which is per-user, unprivileged) actually shows as taking effect.
export function userLpoptionsText() {
    try {
        return readFileSync(join(homedir(), ".cups", "lpoptions"), "utf8")
    } catch {
        return ""
    }
}
export const lpoptionsP = (name) => out("lpoptions", ["-p", name])
export const lpoptionsListP = (name) => out("lpoptions", ["-p", name, "-l"])
export const setPrinterOption = (name, k, v) =>
    run("lpoptions", ["-p", String(name), "-o", String(k) + "=" + String(v)])

// Ask the device itself for supply levels, for a queue that carries none yet.
// ipptool ships with cups; give the device a short leash in case it is asleep.
export function deviceMarkers(uri) {
    let u = String(uri || "")
    if (!/^ipps?:\/\//i.test(u)) return Promise.resolve("")   // dnssd:// etc: skip
    return out("ipptool", ["-tv", u, "get-printer-attributes.test"], { timeout: 6000 })
}
export const lpstatJobs = () => out("lpstat", ["-W", "not-completed", "-o"])
export const lpstatJobsLong = () => out("lpstat", ["-l", "-W", "not-completed", "-o"])
export const lpqAll = () => out("lpq", ["-a"])
export const lpstatCompleted = () => out("lpstat", ["-W", "completed", "-o"])

export const driverlessList = () => out("driverless", [], { timeout: 12000 })
export const avahiBrowse = (svc) =>
    out("avahi-browse", ["-rtp", svc], { timeout: 8000 })

// ---- actions (run as the current user) --------------------------

export const cancelJob = (id) => run("cancel", [String(id)])
export const holdJob = (id) => run("lp", ["-i", String(id), "-H", "hold"])
export const releaseJob = (id) => run("lp", ["-i", String(id), "-H", "resume"])
export const restartJob = (id) => run("lp", ["-i", String(id), "-H", "restart"])
export const setUserDefault = (name) => run("lpoptions", ["-d", String(name)])

export const printTestPage = (name) =>
    run("lp", ["-d", String(name), "-t", "Print Center test page",
        "/usr/share/cups/data/testprint"])

// The one privileged path. `script` comes from printLogic.buildAddScript,
// which validates the queue name and refuses any non-ipp URI.
export const pkexecAdd = (script) => run("pkexec", ["sh", "-c", script], { timeout: 60000 })

export function openSettings() {
    const c = spawn("system-config-printer", [], { detached: true, stdio: "ignore" })
    c.unref()
}

// ---- update checking (read-only) -----------------------------

// GitHub "latest release" for owner/repo. Unauthenticated (60 req/hr/IP).
// Read-only: the plugin only reports that a newer tag exists and links to it.
export async function githubLatestRelease(slug) {
    const { code, stdout } = await run("curl", [
        "-sS", "--max-time", "15", "-L",
        "-H", "Accept: application/vnd.github+json",
        "-H", "User-Agent: omarchy-print-center",
        "https://api.github.com/repos/" + slug + "/releases/latest",
    ], { timeout: 20000 })
    if (code !== 0) return null
    try {
        const j = JSON.parse(stdout)
        return (j && j.tag_name) ? j : null      // 404 / rate-limit bodies have no tag_name
    } catch {
        return null
    }
}

// ---- scanning (SANE) ------------------------------------------

export async function hasCommands(names) {
    const res = {}
    for (const n of names) res[n] = await hasCommand(n)
    return res
}

// Which of the scan packages are not installed (via pacman -Q, cheap).
export async function missingPackages(pkgs) {
    const missing = []
    for (const p of pkgs) {
        const { code } = await run("pacman", ["-Q", p])
        if (code !== 0) missing.push(p)
    }
    return missing
}

export const scanimageList = () => out("scanimage", ["-L"], { timeout: 25000 })
export const scanimageCaps = (device) => out("scanimage", ["-A", "-d", device], { timeout: 20000 })

// Run a scan. `onProgress(text)` gets each stderr chunk (scanimage --progress
// writes "Progress: N%" there). Resolves { code, stderr } — never rejects
// unless scanimage cannot be spawned.
export function runScanimage(args, onProgress) {
    return new Promise((resolve, reject) => {
        let child
        try {
            child = spawn("scanimage", args, { stdio: ["ignore", "ignore", "pipe"] })
        } catch (e) { reject(e); return }
        let stderr = ""
        const killer = setTimeout(() => { try { child.kill("SIGKILL") } catch {} }, 5 * 60 * 1000)
        child.on("error", (e) => { clearTimeout(killer); reject(e) })
        child.stderr.setEncoding("utf8")
        child.stderr.on("data", (d) => { stderr += d; if (onProgress) onProgress(d) })
        child.on("close", (code) => { clearTimeout(killer); resolve({ code: code || 0, stderr }) })
    })
}

export const img2pdf = (files, outPath) =>
    run("img2pdf", [...files, "-o", outPath], { timeout: 120000 })

export function ensureDir(dir) { mkdirSync(dir, { recursive: true }) }

export function makeScanTmpDir() {
    const d = join(tmpdir(), "print-center-scan-" + process.pid + "-" + Date.now())
    mkdirSync(d, { recursive: true })
    return d
}
export function listDir(dir) {
    try { return readdirSync(dir).sort() } catch { return [] }
}
export function rmDir(dir) {
    try { rmSync(dir, { recursive: true, force: true }) } catch {}
}
// rename, falling back to copy+unlink when src/dst are on different mounts
// (the scan temp dir is under /tmp, the output dir under $HOME).
export function moveFile(src, dst) {
    try { renameSync(src, dst) }
    catch { copyFileSync(src, dst); try { unlinkSync(src) } catch {} }
}

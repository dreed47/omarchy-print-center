// Impure side of Print Center: everything that shells out to CUPS / Avahi /
// polkit. Kept apart from printLogic.mjs so the parsers there stay pure.
//
// `run` never rejects on a non-zero exit — callers inspect `code` — and every
// call carries a timeout so a wedged lpstat (network printer asleep) cannot
// park the caller forever.

import { execFile, spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
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
        const { code } = await run("command", ["-v", name], { shell: "/bin/bash" })
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

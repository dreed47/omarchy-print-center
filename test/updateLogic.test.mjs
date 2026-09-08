import { test } from "node:test"
import assert from "node:assert/strict"

import {
    semverGt, parseRelease, repoSlug, buildUpdateInfo,
} from "../printLogic.mjs"

test("semverGt: numeric comparison", () => {
    assert.equal(semverGt("0.4.0", "0.3.0"), true)
    assert.equal(semverGt("0.3.1", "0.3.0"), true)
    assert.equal(semverGt("1.0.0", "0.9.9"), true)
    assert.equal(semverGt("0.3.0", "0.3.0"), false)
    assert.equal(semverGt("0.2.9", "0.3.0"), false)
    assert.equal(semverGt("0.10.0", "0.9.0"), true)       // not string-compared
})

test("semverGt: v-prefix and short forms", () => {
    assert.equal(semverGt("v0.4.0", "0.3.0"), true)
    assert.equal(semverGt("1.2", "1.1.9"), true)
    assert.equal(semverGt("2", "1.9.9"), true)
})

test("semverGt: pre-release sorts before release", () => {
    assert.equal(semverGt("0.3.0", "0.3.0-beta"), true)
    assert.equal(semverGt("0.3.0-beta", "0.3.0"), false)
    assert.equal(semverGt("0.3.0-rc2", "0.3.0-rc1"), true)
})

test("parseRelease", () => {
    const r = parseRelease({
        tag_name: "v0.4.0",
        html_url: "https://github.com/o/r/releases/tag/v0.4.0",
        body: "line one\nline two",
        published_at: "2026-09-09T00:00:00Z",
    })
    assert.deepEqual(r, {
        tag: "v0.4.0",
        version: "0.4.0",
        url: "https://github.com/o/r/releases/tag/v0.4.0",
        notes: "line one\nline two",
        publishedAt: "2026-09-09T00:00:00Z",
    })
    assert.equal(parseRelease(null).version, "")
    assert.equal(parseRelease({}).tag, "")
})

test("repoSlug", () => {
    assert.equal(repoSlug("https://github.com/dreed47/omarchy-print-center.git"), "dreed47/omarchy-print-center")
    assert.equal(repoSlug("https://github.com/dreed47/omarchy-print-center"), "dreed47/omarchy-print-center")
    assert.equal(repoSlug("git@github.com:dreed47/omarchy-print-center.git"), "dreed47/omarchy-print-center")
    assert.equal(repoSlug("not a url"), "")
})

test("buildUpdateInfo: git install, newer release", () => {
    const rel = parseRelease({ tag_name: "v0.4.0", html_url: "u", body: "notes" })
    const i = buildUpdateInfo("0.3.0", rel, "git")
    assert.equal(i.current, "0.3.0")
    assert.equal(i.latest, "0.4.0")
    assert.equal(i.updateAvailable, true)
    assert.equal(i.canSelfUpdate, true)
})

test("buildUpdateInfo: symlink install cannot self-update", () => {
    const rel = parseRelease({ tag_name: "v0.4.0", html_url: "u" })
    const i = buildUpdateInfo("0.3.0", rel, "symlink")
    assert.equal(i.updateAvailable, true)
    assert.equal(i.canSelfUpdate, false)
})

test("buildUpdateInfo: up to date", () => {
    const rel = parseRelease({ tag_name: "v0.3.0", html_url: "u" })
    const i = buildUpdateInfo("0.3.0", rel, "git")
    assert.equal(i.updateAvailable, false)
    assert.equal(i.canSelfUpdate, false)
})

test("buildUpdateInfo: no release reachable", () => {
    const i = buildUpdateInfo("0.3.0", null, "git")
    assert.equal(i.latest, "")
    assert.equal(i.updateAvailable, false)
    assert.equal(i.canSelfUpdate, false)
})

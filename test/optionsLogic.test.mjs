import { test } from "node:test"
import assert from "node:assert/strict"

import {
    parseLpoptionsL, shapePrinterOptions, displayOptionValue, parseIpptoolMarkers,
} from "../printLogic.mjs"

// Real `lpoptions -p Canon-G4080-series -l` output.
const LPOPTS_L = `PageSize/Media Size: 215x345mm 3.5x5 4x6 A4 A4.Borderless A5 A6 B5 Executive Legal *Letter Letter.Borderless Postcard Env10 EnvDL Custom.WIDTHxHEIGHT
InputSlot/Media Source: Auto *Main
MediaType/Media Type: Com.canonMtluster Com.canonMtgr Envelope *Stationery Photographic Auto
cupsPrintQuality/cupsPrintQuality: Draft *Normal High
ColorModel/Output Mode: *RGB Gray
Duplex/Duplex: *None DuplexNoTumble DuplexTumble
OutputBin/OutputBin: *FaceUp`

test("parseLpoptionsL: key/label/values + starred current", () => {
    const rows = parseLpoptionsL(LPOPTS_L)
    const by = Object.fromEntries(rows.map((r) => [r.key, r]))
    assert.equal(by.PageSize.label, "Media Size")
    assert.equal(by.PageSize.current, "Letter")
    assert.ok(by.PageSize.values.includes("Letter") && !by.PageSize.values.some((v) => v.startsWith("*")))
    assert.equal(by.Duplex.current, "None")
    assert.equal(by.ColorModel.current, "RGB")
    assert.equal(by.OutputBin.current, "FaceUp")
})

test("shapePrinterOptions: friendly subset, shortlists, current kept", () => {
    const shaped = shapePrinterOptions(parseLpoptionsL(LPOPTS_L))
    const by = Object.fromEntries(shaped.map((o) => [o.key, o]))

    // hidden: OutputBin, InputSlot label is "Tray" and kept
    assert.ok(!("OutputBin" in by))
    assert.equal(by.InputSlot.label, "Tray")

    // PageSize shortlisted, no Borderless / Custom, current present
    const pv = by.PageSize.values.map((v) => v.value)
    assert.ok(pv.includes("Letter") && pv.includes("A4") && pv.includes("Legal"))
    assert.ok(!pv.some((v) => /Borderless|Custom/.test(v)))
    assert.equal(by.PageSize.current, "Letter")

    // Duplex display mapping
    const dv = by.Duplex.values
    assert.deepEqual(dv.find((v) => v.value === "None"), { value: "None", display: "Off" })
    assert.equal(dv.find((v) => v.value === "DuplexNoTumble").display, "Long edge")

    // MediaType: canon cruft stripped in display, shortlisted
    assert.equal(by.MediaType.label, "Type")
    assert.ok(by.MediaType.values.some((v) => v.value === "Stationery"))
})

test("displayOptionValue", () => {
    assert.equal(displayOptionValue("Duplex", "DuplexTumble"), "Short edge")
    assert.equal(displayOptionValue("sides", "two-sided-long-edge"), "Long edge")
    assert.equal(displayOptionValue("MediaType", "Com.canonMtglossy"), "Mtglossy")
    assert.equal(displayOptionValue("PageSize", "A4"), "A4")
})

test("shapePrinterOptions: nothing recognisable -> empty", () => {
    assert.deepEqual(shapePrinterOptions(parseLpoptionsL("Weird/Weird: a *b c\n")), [])
})

// Real `ipptool -tv <uri> get-printer-attributes.test` marker lines.
const IPPTOOL_OUT = `
        printer-name (nameWithoutLanguage) = Canon-G4080-series
        marker-names (1setOf nameWithoutLanguage) = Black(PGBK),Cyan,Magenta,Yellow,MC
        marker-colors (1setOf nameWithoutLanguage) = #000000,#00CFFF,#F200FF,#FFDA00,#008080
        marker-types (1setOf keyword) = ink-cartridge,ink-cartridge,ink-cartridge,ink-cartridge,waste-ink
        marker-high-levels (1setOf integer) = 100,100,100,100,64
        marker-low-levels (1setOf integer) = 15,15,15,15,0
        marker-levels (1setOf integer) = 90,90,90,88,10
`

test("parseIpptoolMarkers", () => {
    const m = parseIpptoolMarkers(IPPTOOL_OUT)
    assert.equal(m.length, 5)
    assert.deepEqual(m[0], { name: "Black(PGBK)", type: "ink-cartridge", level: 90, low: 15, high: 100 })
    assert.equal(m[3].level, 88)
    assert.equal(m[4].name, "MC")
    assert.equal(m[4].type, "waste-ink")
    assert.equal(m[4].high, 64)
})

test("parseIpptoolMarkers: no marker data -> []", () => {
    assert.deepEqual(parseIpptoolMarkers("printer-state (enum) = idle\n"), [])
})

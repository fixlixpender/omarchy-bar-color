const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

// ------------------------------------------------------------------- color

test("normalizeHex accepts the forms a hex field actually receives", () => {
  assert.equal(Model.normalizeHex("#A1B2C3"), "#a1b2c3")
  assert.equal(Model.normalizeHex("a1b2c3"), "#a1b2c3")
  assert.equal(Model.normalizeHex("  #FFF  "), "#ffffff")
  assert.equal(Model.normalizeHex("#12345"), "")
  assert.equal(Model.normalizeHex("rebeccapurple"), "")
  assert.equal(Model.normalizeHex(null), "")
})

test("hsv survives a round trip through hex", () => {
  const samples = ["#000000", "#ffffff", "#070b08", "#e8544a", "#2fe0b0", "#7f7f7f"]
  for (const hex of samples) {
    const hsv = Model.hexToHsv(hex)
    assert.equal(Model.hsvToHex(hsv.h, hsv.s, hsv.v), hex, hex)
  }
})

test("hexToHsv keeps the caller's hue when the color has none", () => {
  assert.equal(Model.hexToHsv("#808080", 210).h, 210)
  assert.equal(Model.hexToHsv("#000000", 210).h, 210)
  // A color with a real hue reports its own, not the fallback.
  assert.ok(Math.abs(Model.hexToHsv("#e8544a", 210).h - 3.7) < 1)
})

test("contrastRatio matches the WCAG anchors", () => {
  assert.ok(Math.abs(Model.contrastRatio("#ffffff", "#000000") - 21) < 0.01)
  assert.ok(Math.abs(Model.contrastRatio("#777777", "#777777") - 1) < 0.01)
})

test("pickTextColor prefers a theme color that is readable", () => {
  // Matrix theme: green foreground on a near-black bar clears AA easily.
  assert.equal(Model.pickTextColor("#070b08", "#a8f0b8", "#070b08"), "#a8f0b8")
})

test("pickTextColor falls back to pure ink only when the theme cannot cope", () => {
  // A pale bar: neither the pale-green foreground nor the near-black
  // background is the theme's idea of text, but black is readable.
  const picked = Model.pickTextColor("#f2f2f2", "#a8f0b8", "#070b08")
  assert.equal(picked, "#070b08")
  // Mid grey defeats both theme colors and both pure inks are close; take the
  // better of them rather than an unreadable theme color.
  const grey = Model.pickTextColor("#767676", "#8a8a8a", "#7a7a7a")
  assert.ok(grey === "#ffffff" || grey === "#000000")
  assert.ok(Model.contrastRatio(grey, "#767676") > Model.contrastRatio("#8a8a8a", "#767676"))
})

// -------------------------------------------------------------------- toml

const USER_FILE = `[font]
base-size = 12
`

test("adding a section leaves every other line untouched", () => {
  const out = Model.editSection(USER_FILE, "bar", { background: "#334455" })
  assert.equal(out, `[font]
base-size = 12

[bar]
background = "#334455"
`)
})

test("a second key joins the section it belongs to", () => {
  let out = Model.editSection(USER_FILE, "bar", { background: "#334455" })
  out = Model.editSection(out, "bar", { "background-alpha": 0.8 })
  assert.equal(out, `[font]
base-size = 12

[bar]
background = "#334455"
background-alpha = 0.8
`)
  assert.equal(Model.parseSection(out, "font")["base-size"], "12")
})

test("rewriting a key keeps its alignment and its comment", () => {
  const themed = `[bar]
background       = "#070b08"   # the theme's own
background-alpha = 1.0
text             = "#a8f0b8"
`
  const out = Model.editSection(themed, "bar", { background: "#112233" })
  assert.equal(out, `[bar]
background       = "#112233"   # the theme's own
background-alpha = 1.0
text             = "#a8f0b8"
`)
})

test("removing the last key removes the section it emptied", () => {
  let out = Model.editSection(USER_FILE, "bar", { background: "#334455", "background-alpha": 0.5 })
  out = Model.editSection(out, "bar", Model.clearedUpdates())
  assert.equal(out, USER_FILE)
})

test("a section holding a comment is kept even when its keys go", () => {
  const commented = `[bar]
# hand-written note
background = "#334455"
`
  const out = Model.editSection(commented, "bar", Model.clearedUpdates())
  assert.equal(out, `[bar]
# hand-written note
`)
})

test("edits land in the right section when several exist", () => {
  const multi = `[bar]
background = "#111111"

[menu]
background = "#222222"

[font]
base-size = 12
`
  const out = Model.editSection(multi, "menu", { background: "#333333" })
  assert.equal(Model.parseSection(out, "bar").background, "#111111")
  assert.equal(Model.parseSection(out, "menu").background, "#333333")
  assert.equal(Model.parseSection(out, "font")["base-size"], "12")
})

test("an empty or missing file becomes a valid one", () => {
  assert.equal(Model.editSection("", "bar", { background: "#334455" }), `[bar]
background = "#334455"
`)
  assert.equal(Model.editSection(undefined, "bar", Model.clearedUpdates()), "")
})

test("a file without a trailing newline gains one rather than a joined line", () => {
  const out = Model.editSection("[font]\nbase-size = 12", "bar", { background: "#334455" })
  assert.ok(out.endsWith('background = "#334455"\n'))
  assert.equal(Model.parseSection(out, "font")["base-size"], "12")
})

test("barUpdates writes an override only where it differs from the theme", () => {
  assert.deepEqual(Model.barUpdates("#334455", 1.0, "#ffffff"), {
    "background": "#334455",
    "background-alpha": null,
    "text": "#ffffff"
  })
  assert.deepEqual(Model.barUpdates("#334455", 0.75, ""), {
    "background": "#334455",
    "background-alpha": 0.75,
    "text": null
  })
})

test("an alpha override survives the write/read round trip", () => {
  const out = Model.editSection(USER_FILE, "bar", Model.barUpdates("#334455", 0.66, "#eeeeee"))
  const values = Model.parseSection(out, "bar")
  assert.equal(values.background, "#334455")
  assert.equal(Number(values["background-alpha"]), 0.66)
  assert.equal(values.text, "#eeeeee")
})

test("parsePalette pulls theme colors in order and drops repeats", () => {
  const colors = `mode = "dark"
accent = "#00ff5f"
background = "#070b08"
dark_background = "#070b08"
foreground = "#a8f0b8"
red = "#e8544a"
hyprland_active_border = "rgba(00ff5fee) rgba(007a2aee) 45deg"
`
  const palette = Model.parsePalette(colors)
  assert.deepEqual(palette.map(p => p.key), ["background", "foreground", "accent", "red"])
  assert.equal(palette[0].hex, "#070b08")
})

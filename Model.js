// Pure logic for the Bar Color plugin: the color math behind the picker and
// the surgical edit that lands the result in shell.toml.
//
// Nothing here imports QML or touches the filesystem, so `node --test` runs
// exactly the code the panel runs.
//
// The TOML editor is deliberately line-based rather than a real parser. The
// file it edits is shared — `omarchy display text size` writes `[font]
// base-size` into it and the user may have hand-written anything else — so
// every line this plugin does not own has to survive byte for byte, comments
// and alignment included. A parse/serialize round-trip would quietly reformat
// all of it.

// ------------------------------------------------------------------- color

function clamp(value, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return min
  return n < min ? min : (n > max ? max : n)
}

// Accepts "#rrggbb", "rrggbb", "#rgb" and any casing. Returns "" for anything
// else, which is what makes it safe to feed the hex field's every keystroke.
function normalizeHex(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text.charAt(0) === "#") text = text.slice(1)
  if (/^[0-9a-f]{3}$/.test(text)) {
    text = text.charAt(0) + text.charAt(0) + text.charAt(1) + text.charAt(1) + text.charAt(2) + text.charAt(2)
  }
  if (!/^[0-9a-f]{6}$/.test(text)) return ""
  return "#" + text
}

function hexToRgb(value) {
  var hex = normalizeHex(value)
  if (hex === "") return null
  return {
    r: parseInt(hex.substr(1, 2), 16),
    g: parseInt(hex.substr(3, 2), 16),
    b: parseInt(hex.substr(5, 2), 16)
  }
}

function rgbToHex(rgb) {
  function channel(v) {
    var n = Math.round(clamp(v, 0, 255))
    return (n < 16 ? "0" : "") + n.toString(16)
  }
  return "#" + channel(rgb.r) + channel(rgb.g) + channel(rgb.b)
}

// Hue in degrees (0-360), saturation and value in 0-1.
function rgbToHsv(rgb) {
  var r = clamp(rgb.r, 0, 255) / 255
  var g = clamp(rgb.g, 0, 255) / 255
  var b = clamp(rgb.b, 0, 255) / 255
  var max = Math.max(r, g, b)
  var min = Math.min(r, g, b)
  var delta = max - min
  var hue = 0
  if (delta > 0) {
    if (max === r) hue = 60 * (((g - b) / delta) % 6)
    else if (max === g) hue = 60 * ((b - r) / delta + 2)
    else hue = 60 * ((r - g) / delta + 4)
  }
  if (hue < 0) hue += 360
  return { h: hue, s: max === 0 ? 0 : delta / max, v: max }
}

function hsvToRgb(h, s, v) {
  var hue = Number(h)
  if (!isFinite(hue)) hue = 0
  hue = ((hue % 360) + 360) % 360
  var sat = clamp(s, 0, 1)
  var val = clamp(v, 0, 1)
  var c = val * sat
  var x = c * (1 - Math.abs(((hue / 60) % 2) - 1))
  var m = val - c
  var rgb
  if (hue < 60) rgb = [c, x, 0]
  else if (hue < 120) rgb = [x, c, 0]
  else if (hue < 180) rgb = [0, c, x]
  else if (hue < 240) rgb = [0, x, c]
  else if (hue < 300) rgb = [x, 0, c]
  else rgb = [c, 0, x]
  return { r: (rgb[0] + m) * 255, g: (rgb[1] + m) * 255, b: (rgb[2] + m) * 255 }
}

function hsvToHex(h, s, v) {
  return rgbToHex(hsvToRgb(h, s, v))
}

function hexToHsv(value, fallbackHue) {
  var rgb = hexToRgb(value)
  if (!rgb) return null
  var hsv = rgbToHsv(rgb)
  // Grey has no hue to recover. Keeping the hue the picker already had stops
  // the cursor from snapping back to red every time the user drags saturation
  // to zero and back out again.
  if (hsv.s === 0 && fallbackHue !== undefined && fallbackHue !== null) hsv.h = Number(fallbackHue) || 0
  return hsv
}

// WCAG relative luminance, used only to keep bar text legible against a
// background the user is free to pick badly.
function relativeLuminance(value) {
  var rgb = hexToRgb(value)
  if (!rgb) return 0
  function linear(channel) {
    var c = channel / 255
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
}

function contrastRatio(a, b) {
  if (normalizeHex(a) === "" || normalizeHex(b) === "") return 1
  var la = relativeLuminance(a)
  var lb = relativeLuminance(b)
  var lighter = Math.max(la, lb)
  var darker = Math.min(la, lb)
  return (lighter + 0.05) / (darker + 0.05)
}

var CONTRAST_TARGET = 4.5

// Pick bar text for a chosen background, preferring colors the active theme
// already uses. Only when neither theme color clears the WCAG AA threshold
// does this reach for plain white or black — a readable bar beats a
// theme-pure one, but not by default.
function pickTextColor(background, themeForeground, themeBackground) {
  var bg = normalizeHex(background)
  if (bg === "") return ""

  var best = ""
  var bestRatio = 0
  var candidates = [normalizeHex(themeForeground), normalizeHex(themeBackground)]
  for (var i = 0; i < candidates.length; i++) {
    if (candidates[i] === "") continue
    var ratio = contrastRatio(candidates[i], bg)
    if (ratio > bestRatio) { best = candidates[i]; bestRatio = ratio }
  }
  if (best !== "" && bestRatio >= CONTRAST_TARGET) return best

  var pure = contrastRatio("#ffffff", bg) >= contrastRatio("#000000", bg) ? "#ffffff" : "#000000"
  if (best === "") return pure
  return contrastRatio(pure, bg) > bestRatio ? pure : best
}

// -------------------------------------------------------------------- toml

function escapeForRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\-]/g, "\\$&")
}

function sectionNameOf(line) {
  var match = String(line).match(/^\s*\[([^\]]+)\]\s*(#.*)?$/)
  return match ? match[1].replace(/^\s+|\s+$/g, "") : null
}

// Groups: 1 indent, 2 key, 3 the "=" and its padding, 4 value, 5 trailing
// comment. Splitting it this way is what lets a rewrite keep a theme file's
// column alignment and any comment sitting after the value.
function keyLinePattern(key) {
  return new RegExp("^(\\s*)(" + escapeForRegex(key) + ")(\\s*=\\s*)(\"[^\"]*\"|'[^']*'|[^#]*?)(\\s*#.*)?$")
}

function unquote(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  var match = text.match(/^"([^"]*)"$/) || text.match(/^'([^']*)'$/)
  return match ? match[1] : text
}

// Flat {key: value} view of one section. Values come back as strings with
// quotes stripped; callers coerce.
function parseSection(text, section) {
  var out = {}
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var current = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var name = sectionNameOf(line)
    if (name !== null) { current = name; continue }
    if (current !== section) continue
    var kv = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*("[^"]*"|'[^']*'|[^#]*?)\s*(#.*)?$/)
    if (kv) out[kv[1]] = unquote(kv[2])
  }
  return out
}

function formatValue(value) {
  if (typeof value === "number") {
    if (!isFinite(value)) return "0"
    var rounded = Math.round(value * 100) / 100
    return String(rounded)
  }
  return '"' + String(value).replace(/"/g, "") + '"'
}

function formatEntry(key, value) {
  return key + " = " + formatValue(value)
}

function findKeyLine(lines, from, to, key) {
  var pattern = keyLinePattern(key)
  for (var i = from; i < to; i++) {
    if (pattern.test(lines[i])) return i
  }
  return -1
}

function rewriteKeyLine(line, key, value) {
  var match = String(line).match(keyLinePattern(key))
  if (!match) return formatEntry(key, value)
  return match[1] + key + match[3] + formatValue(value) + (match[5] || "")
}

function rangeHasContent(lines, from, to) {
  for (var i = from; i < to; i++) {
    if (String(lines[i]).replace(/^\s+|\s+$/g, "") !== "") return true
  }
  return false
}

function joinLines(lines) {
  while (lines.length > 0 && String(lines[lines.length - 1]).replace(/^\s+|\s+$/g, "") === "") lines.pop()
  return lines.length === 0 ? "" : lines.join("\n") + "\n"
}

// Apply {key: value} to one section. A null or undefined value removes the
// key; a section left with nothing but blank lines is removed with it, so
// resetting to the theme leaves the file as it was found rather than
// accumulating an empty `[bar]` header.
function editSection(text, section, updates) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()

  var keys = Object.keys(updates || {})
  var header = -1
  var i

  for (i = 0; i < lines.length; i++) {
    if (sectionNameOf(lines[i]) === section) { header = i; break }
  }

  if (header === -1) {
    var added = []
    for (i = 0; i < keys.length; i++) {
      var fresh = updates[keys[i]]
      if (fresh === null || fresh === undefined) continue
      added.push(formatEntry(keys[i], fresh))
    }
    if (added.length === 0) return joinLines(lines)
    if (lines.length > 0 && String(lines[lines.length - 1]).replace(/^\s+|\s+$/g, "") !== "") lines.push("")
    lines.push("[" + section + "]")
    return joinLines(lines.concat(added))
  }

  var end = lines.length
  for (i = header + 1; i < lines.length; i++) {
    if (sectionNameOf(lines[i]) !== null) { end = i; break }
  }

  for (i = 0; i < keys.length; i++) {
    var key = keys[i]
    var value = updates[key]
    var at = findKeyLine(lines, header + 1, end, key)
    if (value === null || value === undefined) {
      if (at !== -1) { lines.splice(at, 1); end-- }
      continue
    }
    if (at !== -1) {
      lines[at] = rewriteKeyLine(lines[at], key, value)
      continue
    }
    var insertAt = header + 1
    for (var s = header + 1; s < end; s++) {
      if (String(lines[s]).replace(/^\s+|\s+$/g, "") !== "") insertAt = s + 1
    }
    lines.splice(insertAt, 0, formatEntry(key, value))
    end++
  }

  if (!rangeHasContent(lines, header + 1, end)) {
    lines.splice(header, end - header)
    // The removal can leave the blank line that preceded the section stacked
    // on the one that followed it.
    if (header > 0 && header < lines.length
        && String(lines[header - 1]).replace(/^\s+|\s+$/g, "") === ""
        && String(lines[header]).replace(/^\s+|\s+$/g, "") === "") {
      lines.splice(header, 1)
    }
  }

  return joinLines(lines)
}

// The three keys this plugin owns, as one update object. Alpha of 1 and
// theme-managed text are expressed as removals rather than as written
// defaults: an override is only on disk while it differs from the theme.
function barUpdates(hex, alpha, textHex) {
  var background = normalizeHex(hex)
  var updates = {}
  updates["background"] = background === "" ? null : background
  updates["background-alpha"] = (Number(alpha) >= 0.999 || background === "") ? null : clamp(alpha, 0, 1)
  var text = normalizeHex(textHex)
  updates["text"] = text === "" ? null : text
  return updates
}

function clearedUpdates() {
  return { "background": null, "background-alpha": null, "text": null }
}

// A curated slice of the theme's own palette, in a readable order and with
// duplicates dropped, for the preset row.
var PALETTE_KEYS = [
  "background", "dark_background", "darker_background", "lighter_background",
  "foreground", "dark_foreground", "accent", "muted",
  "red", "orange", "yellow", "green", "cyan", "blue", "magenta", "brown"
]

function parsePalette(colorsToml) {
  var seen = {}
  var out = []
  var lines = String(colorsToml === undefined || colorsToml === null ? "" : colorsToml).split("\n")
  var found = {}
  for (var i = 0; i < lines.length; i++) {
    var kv = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (kv && found[kv[1]] === undefined) found[kv[1]] = normalizeHex(kv[2])
  }
  for (var k = 0; k < PALETTE_KEYS.length; k++) {
    var hex = found[PALETTE_KEYS[k]]
    if (!hex || seen[hex]) continue
    seen[hex] = true
    out.push({ key: PALETTE_KEYS[k], hex: hex })
  }
  return out
}

// ----------------------------------------------------------------- exports

if (typeof module !== "undefined") {
  module.exports = {
    CONTRAST_TARGET: CONTRAST_TARGET,
    PALETTE_KEYS: PALETTE_KEYS,
    clamp: clamp,
    normalizeHex: normalizeHex,
    hexToRgb: hexToRgb,
    rgbToHex: rgbToHex,
    rgbToHsv: rgbToHsv,
    hsvToRgb: hsvToRgb,
    hsvToHex: hsvToHex,
    hexToHsv: hexToHsv,
    relativeLuminance: relativeLuminance,
    contrastRatio: contrastRatio,
    pickTextColor: pickTextColor,
    sectionNameOf: sectionNameOf,
    parseSection: parseSection,
    editSection: editSection,
    barUpdates: barUpdates,
    clearedUpdates: clearedUpdates,
    parsePalette: parsePalette
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The three files this plugin reads and the one it writes.
//
// It writes ~/.config/omarchy/shell.toml, the machine-level override the shell
// layers on top of the active theme. That choice is what makes the plugin's
// color survive a theme switch (which replaces only the theme's own values)
// and apply the instant the file lands — Color's FileView on it is watched, so
// there is no restart, no IPC, and no reload command in this plugin at all.
//
// The two theme files are read only, for the "theme default" chip and the
// preset row.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string userPath: configDir + "/omarchy/shell.toml"
  readonly property string themeDir: stateHome + "/omarchy/current/theme"

  property string source: ""
  property bool ready: false

  // Bumped on every load and every save so consumers can react to "the
  // document changed" without deep-comparing it.
  property int revision: 0

  readonly property var barValues: {
    revision  // reactive dependency: parseSection is a plain function call
    return Model.parseSection(source, "bar")
  }
  readonly property string overrideHex: Model.normalizeHex(barValues["background"])
  readonly property real overrideAlpha: {
    var raw = Number(barValues["background-alpha"])
    return isFinite(raw) ? Model.clamp(raw, 0, 1) : 1
  }
  readonly property string overrideTextHex: Model.normalizeHex(barValues["text"])
  readonly property bool overridden: overrideHex !== ""

  // Theme side. `themeBarHex` is what the bar would be with no override, which
  // is both the reset target and the first preset chip.
  property string themeShell: ""
  property string themeColors: ""
  readonly property string themeBarHex: {
    var hex = Model.normalizeHex(Model.parseSection(themeShell, "bar")["background"])
    return hex !== "" ? hex : Model.normalizeHex(String(Color.background))
  }
  readonly property string themeBarTextHex: {
    var hex = Model.normalizeHex(Model.parseSection(themeShell, "bar")["text"])
    return hex !== "" ? hex : Model.normalizeHex(String(Color.foreground))
  }
  readonly property var themePalette: Model.parsePalette(themeColors)

  // Transparency is bar state in shell.json rather than theme state in
  // shell.toml, and while it is on the bar paints no background at all — so
  // the panel has to know about it to be honest about what a color will do.
  // Read here and written only through `omarchy bar transparent`, which owns
  // that file's schema.
  property bool barTransparent: false

  // The exact text of our most recent write. Every write comes back through
  // the watcher a moment later; consumers compare against this to tell their
  // own echo from somebody else's edit.
  property string lastWritten: ""

  signal changed()

  // Apply an update object to the [bar] section. Writing the file is the whole
  // mechanism: the shell is already watching it.
  function write(updates) {
    var next = Model.editSection(source, "bar", updates)
    if (next === source) return
    source = next
    lastWritten = next
    revision++
    userFile.setText(next)
  }

  function apply(text) {
    source = String(text || "")
    revision++
    ready = true
    changed()
  }

  FileView {
    id: userFile
    path: root.userPath
    watchChanges: true
    atomicWrites: true
    printErrors: false

    onLoaded: root.apply(text())
    // First run on a machine that never customized anything: no file yet.
    onLoadFailed: root.apply("")
    // text() is stale inside the change signal, so re-read and let onLoaded
    // parse fresh content. This is the path a hand-edit arrives on, and the
    // path our own write echoes back on.
    onFileChanged: reload()
  }

  // A FileView watching a path that does not exist yet can emit neither
  // onLoaded nor onLoadFailed. Without this the store would never become
  // ready and the panel would open onto nothing.
  Timer {
    interval: 500
    running: !root.ready
    repeat: false
    onTriggered: if (!root.ready) root.apply("")
  }

  FileView {
    id: barConfigFile
    path: root.configDir + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false

    function adopt(raw) {
      try {
        var parsed = JSON.parse(String(raw || "{}"))
        root.barTransparent = !!(parsed && parsed.bar && parsed.bar.transparent)
      } catch (error) {
        // A half-written file during someone else's save is not worth
        // reporting; the next change signal brings a complete one.
      }
    }

    onLoaded: adopt(text())
    onFileChanged: reload()
  }

  FileView {
    id: themeShellFile
    path: root.themeDir + "/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeShell = text()
    onLoadFailed: root.themeShell = ""
    onFileChanged: reload()
  }

  FileView {
    id: themeColorsFile
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeColors = text()
    onLoadFailed: root.themeColors = ""
    onFileChanged: reload()
  }

  // `current/theme` is a symlink that theme switching retargets, and a watch
  // on a path through a symlink does not reliably see that. The shell is
  // handed the new palette over IPC at the same moment, so the foundational
  // colors changing is the signal that the two theme files above are stale.
  readonly property string themeSignature: String(Color.background) + "/" + String(Color.accent) + "/" + String(Color.foreground)
  onThemeSignatureChanged: {
    themeShellFile.reload()
    themeColorsFile.reload()
  }

  Component.onCompleted: {
    userFile.reload()
    barConfigFile.reload()
    themeShellFile.reload()
    themeColorsFile.reload()
  }
}

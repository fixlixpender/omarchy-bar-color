import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The picker popup.
//
// Hue, saturation and value are the authoritative draft state while the panel
// is open — not the hex string, and not what is on disk. Recovering hue from a
// hex color is lossy at the grey and black edges of the field, so a picker
// that round-tripped through hex on every drag would fight the user's cursor.
// Disk is adopted into the draft only while the panel is closed, which is also
// what keeps our own write echoing back through the file watcher from
// stuttering a drag in flight.
Panel {
  id: root
  moduleName: "filipe.bar-color"
  ipcTarget: "bar-color"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits, and `omarchy-shell bar-color toggle` can bind to a key.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Store { id: store }

  // ------------------------------------------------------------------ draft

  property real hue: 0
  property real saturation: 0
  property real brightness: 0.1
  property real alpha: 1
  // On by default: the one way a color picker can leave a desktop unusable is
  // a pale bar wearing the theme's pale text.
  property bool autoText: true

  readonly property string draftHex: Model.hsvToHex(hue, saturation, brightness)
  readonly property string themeHex: store.themeBarHex
  readonly property string themeTextHex: store.themeBarTextHex

  // The foundational theme palette, which `pickTextColor` prefers over plain
  // white or black. Read from the Color singleton rather than the theme file
  // so it is right even for a theme that ships no shell.toml.
  readonly property string paletteForeground: Model.normalizeHex(String(Color.foreground))
  readonly property string paletteBackground: Model.normalizeHex(String(Color.background))

  readonly property string autoTextHex: Model.pickTextColor(draftHex, paletteForeground, paletteBackground)
  readonly property string effectiveTextHex: autoText ? autoTextHex : themeTextHex
  readonly property real contrast: Model.contrastRatio(effectiveTextHex, draftHex)
  readonly property bool contrastOk: contrast >= Model.CONTRAST_TARGET

  readonly property bool overridden: store.overridden
  readonly property bool barTransparent: store.barTransparent

  // ------------------------------------------------------------- lifecycle

  function seedFromDisk() {
    var hex = store.overrideHex !== "" ? store.overrideHex : themeHex
    var hsv = Model.hexToHsv(hex, hue)
    if (hsv) {
      hue = hsv.h
      saturation = hsv.s
      brightness = hsv.v
    }
    alpha = store.overrideHex !== "" ? store.overrideAlpha : 1
    autoText = store.overrideTextHex !== ""
  }

  Connections {
    target: store

    // Every write of ours comes back through the file watcher, and adopting
    // that echo mid-drag would drag the cursor backwards to whatever the last
    // coalesced write happened to catch. Skip our own; adopt everyone else's,
    // open or not, so a theme switch or a hand-edit shows up here immediately.
    function onChanged() {
      if (store.source !== store.lastWritten) root.seedFromDisk()
    }
  }

  onThemeHexChanged: if (!opened && !store.overridden) seedFromDisk()

  onOpenedChanged: if (opened) seedFromDisk()

  Component.onCompleted: if (store.ready) seedFromDisk()

  // ------------------------------------------------------------------ edits

  function setHsv(h, s, v) {
    hue = h
    saturation = s
    brightness = v
    previewTimer.restart()
  }

  function setHex(value) {
    var hex = Model.normalizeHex(value)
    if (hex === "") return false
    var hsv = Model.hexToHsv(hex, hue)
    setHsv(hsv.h, hsv.s, hsv.v)
    commit()
    return true
  }

  function commit() {
    previewTimer.stop()
    store.write(Model.barUpdates(draftHex, alpha, autoText ? autoTextHex : ""))
  }

  function resetToTheme() {
    previewTimer.stop()
    autoText = false
    store.write(Model.clearedUpdates())
    seedFromDisk()
  }

  // A drag is a stream of values and each write is a file the shell re-reads.
  // Coalescing them into one write per frame-ish keeps the bar following the
  // cursor without turning a drag into a hundred round-trips through disk.
  Timer {
    id: previewTimer
    interval: 90
    repeat: false
    onTriggered: root.commit()
  }

  // Transparency belongs to the bar's own config, so it goes through the
  // command that owns it; the store is watching shell.json and reports the
  // result back. Nothing here has to guess whether it worked.
  function setTransparent(value) {
    if (!bar) return
    bar.run("omarchy bar transparent " + (value ? "true" : "false"))
  }

  Component.onDestruction: previewTimer.stop()

  IpcHandler {
    target: "bar-color"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // ------------------------------------------------------------------- view

  readonly property color fg: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.55)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hexField.activeFocus

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Arrows nudge the color the same way they nudge a slider elsewhere in
      // the shell: left/right walk the hue, up/down the brightness.
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.setHsv(root.hue + dx * 6, Math.max(0.08, root.saturation), Math.max(0.08, root.brightness))
        if (dy !== 0) root.setHsv(root.hue, root.saturation, Model.clamp(root.brightness - dy * 0.04, 0, 1))
        root.commit()
      }

      onTextKey: function(key) {
        if (key === "r") root.resetToTheme()
        else if (key === "t") root.setTransparent(!root.barTransparent)
        else if (key === "c") { root.autoText = !root.autoText; root.commit() }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.xl

        // ------------------------------------------------------- header

        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, swatch.height)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              id: title
              textFormat: Text.PlainText
              text: "Bar Color"
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: store.overridden ? "Overriding the theme" : "Following the theme"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            id: swatch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(52)
            height: Style.space(26)
            radius: Style.cornerRadius
            color: Qt.rgba(previewColor.r, previewColor.g, previewColor.b, root.alpha)
            border.width: Math.max(1, Style.spacing.hairline)
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)

            readonly property color previewColor: root.barTransparent ? "transparent" : root.draftHex

            // The swatch is a rehearsal of the bar itself, text included, so
            // the contrast number below has something to point at.
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.barTransparent ? "off" : "abc"
              color: root.barTransparent ? root.faint : root.effectiveTextHex
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // -------------------------------------------------------- picker

        ColorField {
          id: field
          width: parent.width
          hue: root.hue
          saturation: root.saturation
          value: root.brightness
          foreground: root.fg
          opacity: root.barTransparent ? 0.45 : 1

          onMoved: function(h, s, v) { root.setHsv(h, s, v) }
          onCommitted: root.commit()
        }

        // ------------------------------------------------- hex + contrast

        Row {
          width: parent.width
          spacing: Style.spacing.lg

          TextField {
            id: hexField
            width: Style.space(100)
            foreground: root.fg
            accent: root.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            // Bound to the draft while unfocused, free to be typed into while
            // focused — otherwise every keystroke would be overwritten by the
            // color the field has not been told about yet.
            text: activeFocus ? text : root.draftHex
            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
            maximumLength: 7

            onAccepted: {
              if (!root.setHex(text)) text = root.draftHex
              focus = false
            }
            onActiveFocusChanged: if (!activeFocus) text = root.draftHex
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              text: "Text contrast " + root.contrast.toFixed(1) + ":1"
              color: root.contrastOk ? root.faint : Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.contrastOk
              text: root.autoText ? "Below AA even at best" : "Try matching text color"
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ------------------------------------------------- theme presets

        Column {
          width: parent.width
          spacing: Style.spacing.md
          visible: chips.model.length > 0

          PanelSectionHeader {
            text: "Theme palette"
            foreground: root.faint
            fontFamily: Style.font.family
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              id: chips
              model: {
                var out = [{ key: "theme", hex: root.themeHex }]
                var palette = store.themePalette
                for (var i = 0; i < palette.length; i++) {
                  if (palette[i].hex !== root.themeHex) out.push(palette[i])
                }
                return out
              }

              delegate: Rectangle {
                required property var modelData
                readonly property bool current: modelData.hex === root.draftHex

                width: Style.space(22)
                height: Style.space(22)
                radius: Style.cornerRadius
                color: modelData.hex
                border.width: current ? 2 : Math.max(1, Style.spacing.hairline)
                border.color: current ? root.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.3)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setHex(parent.modelData.hex)
                  onEntered: if (root.bar) root.bar.showTooltip(parent, parent.modelData.key + " · " + parent.modelData.hex)
                  onExited: if (root.bar) root.bar.hideTooltip(parent)
                }
              }
            }
          }
        }

        // -------------------------------------------------------- opacity

        Column {
          width: parent.width
          spacing: Style.spacing.md

          Item {
            width: parent.width
            height: opacityLabel.implicitHeight

            PanelSectionHeader {
              id: opacityLabel
              anchors.left: parent.left
              text: "Opacity"
              foreground: root.faint
              fontFamily: Style.font.family
            }

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: Math.round(root.alpha * 100) + "%"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            // PanelSlider colors itself from the bar's text color by default,
            // and "Match text color" is free to set that to something dark.
            // Inside a popup the popup's own text color is the one that is
            // guaranteed to be legible against what is behind the slider.
            fillColor: root.fg
            knobColor: root.fg
            trackColor: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
            // Below about a tenth the bar stops being a bar; the transparency
            // switch below is the honest way to ask for none of it.
            minimum: 0.1
            maximum: 1
            step: 0.05
            value: root.alpha
            enabled: !root.barTransparent
            opacity: root.barTransparent ? 0.45 : 1

            onMoved: function(value) { root.alpha = value; previewTimer.restart() }
            onReleased: function(value) { root.alpha = value; root.commit() }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.fg
        }

        // -------------------------------------------------------- switches

        Toggle {
          width: parent.width
          label: "Match text color"
          description: root.autoText
            ? "Bar text set to " + root.autoTextHex
            : "Bar text left to the theme"
          checked: root.autoText
          foreground: root.fg
          accent: root.accent
          fontFamily: Style.font.family

          onClicked: {
            root.autoText = !root.autoText
            root.commit()
          }
        }

        Toggle {
          width: parent.width
          label: "Transparent bar"
          description: root.barTransparent
            ? "The bar paints no background; this color is unused"
            : "Drop the background entirely"
          checked: root.barTransparent
          foreground: root.fg
          accent: root.accent
          fontFamily: Style.font.family

          onClicked: root.setTransparent(!root.barTransparent)
        }

        // ---------------------------------------------------------- reset

        Button {
          width: parent.width
          text: "Reset to theme"
          enabled: store.overridden
          opacity: store.overridden ? 1 : 0.45
          foreground: root.fg
          accent: root.accent
          fontFamily: Style.font.family
          bordered: true

          onClicked: root.resetToTheme()
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Saved to ~/.config/omarchy/shell.toml · survives theme switches"
          color: root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}

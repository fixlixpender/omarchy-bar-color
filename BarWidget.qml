import QtQuick
import qs.Commons
import qs.Ui

// The bar button: a swatch of the color the bar is currently wearing, so the
// widget reads as what it controls rather than as a generic glyph. A
// transparent bar leaves the swatch hollow, which is the truth about it.
BarWidget {
  id: root
  moduleName: "fixlixpender.bar-color"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool transparentBar: bar ? bar.transparent === true : false
  readonly property color swatchColor: bar ? bar.background : Color.bar.background
  readonly property bool overridden: panelLoader.item ? panelLoader.item.overridden === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function resetToTheme() {
    if (panelLoader.item && panelLoader.item.resetToTheme) panelLoader.item.resetToTheme()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Loaded eagerly rather than on first click: the panel owns the store, and
  // right-click reset has to work without opening anything.
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (root.transparentBar) return "Bar color · transparent"
      var hex = String(root.swatchColor).slice(0, 7)
      return "Bar color · " + hex + (root.overridden ? "" : " (theme)") + "  ·  right-click resets"
    }

    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: Math.round(parent.width * 0.8)
          height: width
          radius: Style.cornerRadius > 0 ? width / 2 : Math.max(1, Style.space(2))
          color: root.transparentBar ? "transparent" : root.swatchColor
          border.width: Math.max(1, Style.spacing.hairline)
          border.color: button.foreground

          // A near-black swatch on a near-black bar is a hole; the inner ring
          // keeps the shape legible whatever the color is set to.
          Rectangle {
            anchors.fill: parent
            anchors.margins: Math.max(1, Style.spacing.hairline)
            radius: parent.radius
            color: "transparent"
            border.width: Math.max(1, Style.spacing.hairline)
            border.color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.25)
          }
        }
      }
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.togglePanel()
      else if (mouseButton === Qt.RightButton) root.resetToTheme()
    }
  }
}

import QtQuick
import qs.Commons

// The picker proper: a saturation/value field with a hue rail beside it.
//
// Drawn with plain QtQuick gradients rather than a Canvas or a shader, so it
// costs nothing to keep live while the pointer drags. The field is the hue at
// full strength, washed to white across x and to black down y — the standard
// HSV square, and the reason hue/saturation/value are the state this component
// owns rather than a color it would have to decompose on every frame.
Item {
  id: root

  property real hue: 0        // degrees, 0-360
  property real saturation: 0 // 0-1
  property real value: 0      // 0-1

  property color foreground: Color.popups.text
  property real railWidth: Style.space(14)
  property real fieldHeight: Style.space(132)
  property real handleSize: Style.space(12)

  // Emitted continuously through a drag; `committed` fires once on release, so
  // the panel can preview freely and only persist when the user settles.
  signal moved(real hue, real saturation, real value)
  signal committed()

  function clamp01(v) {
    return v < 0 ? 0 : (v > 1 ? 1 : v)
  }

  implicitHeight: fieldHeight

  readonly property color hueColor: Qt.hsva(((hue % 360) + 360) % 360 / 360, 1, 1, 1)
  readonly property color currentColor: Qt.hsva(((hue % 360) + 360) % 360 / 360, saturation, value, 1)

  // A handle over a dark patch of the field needs a light ring and vice versa;
  // one fixed ring color disappears at one end or the other.
  readonly property color handleInk: value > 0.55 && saturation < 0.75 ? "#000000" : "#ffffff"

  Row {
    anchors.fill: parent
    spacing: Style.spacing.lg

    Rectangle {
      id: field
      width: parent.width - root.railWidth - parent.spacing
      height: parent.height
      color: root.hueColor
      radius: Style.cornerRadius
      clip: true

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: "#ffffffff" }
          GradientStop { position: 1.0; color: "#00ffffff" }
        }
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
          orientation: Gradient.Vertical
          GradientStop { position: 0.0; color: "#00000000" }
          GradientStop { position: 1.0; color: "#ff000000" }
        }
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.width: Math.max(1, Style.spacing.hairline)
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
      }

      Rectangle {
        id: handle
        width: root.handleSize
        height: root.handleSize
        radius: width / 2
        x: Math.round(root.saturation * field.width - width / 2)
        y: Math.round((1 - root.value) * field.height - height / 2)
        color: "transparent"
        border.width: 2
        border.color: root.handleInk

        Rectangle {
          anchors.fill: parent
          anchors.margins: 2
          radius: width / 2
          color: "transparent"
          border.width: 1
          border.color: Qt.rgba(root.handleInk.r, root.handleInk.g, root.handleInk.b, 0.35)
        }
      }

      MouseArea {
        anchors.fill: parent
        preventStealing: true
        cursorShape: Qt.CrossCursor

        function pick(mouse) {
          var s = root.clamp01(mouse.x / Math.max(1, field.width))
          var v = 1 - root.clamp01(mouse.y / Math.max(1, field.height))
          root.moved(root.hue, s, v)
        }

        onPressed: function(mouse) { pick(mouse) }
        onPositionChanged: function(mouse) { if (pressed) pick(mouse) }
        onReleased: root.committed()
      }
    }

    Rectangle {
      id: rail
      width: root.railWidth
      height: parent.height
      radius: Style.cornerRadius
      clip: true

      gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0000; color: "#ff0000" }
        GradientStop { position: 0.1667; color: "#ffff00" }
        GradientStop { position: 0.3333; color: "#00ff00" }
        GradientStop { position: 0.5000; color: "#00ffff" }
        GradientStop { position: 0.6667; color: "#0000ff" }
        GradientStop { position: 0.8333; color: "#ff00ff" }
        GradientStop { position: 1.0000; color: "#ff0000" }
      }

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.width: Math.max(1, Style.spacing.hairline)
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
      }

      Rectangle {
        width: parent.width
        height: Math.max(2, Style.space(3))
        y: Math.round((((root.hue % 360) + 360) % 360) / 360 * (rail.height - height))
        color: "transparent"
        border.width: Math.max(1, Style.spacing.hairline)
        border.color: "#ffffff"

        Rectangle {
          anchors.fill: parent
          anchors.margins: 1
          color: "transparent"
          border.width: 1
          border.color: "#66000000"
        }
      }

      MouseArea {
        anchors.fill: parent
        preventStealing: true
        cursorShape: Qt.CrossCursor

        function pick(mouse) {
          var h = root.clamp01(mouse.y / Math.max(1, rail.height)) * 360
          // Saturation and value of zero leave nothing for a hue change to
          // show, so lift them just off the corner rather than letting the
          // rail look broken on a black bar.
          var s = root.saturation <= 0.01 && root.value <= 0.01 ? 0.6 : root.saturation
          var v = root.value <= 0.01 ? 0.5 : root.value
          root.moved(h, s, v)
        }

        onPressed: function(mouse) { pick(mouse) }
        onPositionChanged: function(mouse) { if (pressed) pick(mouse) }
        onReleased: root.committed()
      }
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Left: open the translator. Right: clipboard popups on/off.
// Middle: unload the model now. Accent colour while the model is in RAM.
BarWidget {
  id: root
  moduleName: "io.github.lekonidus.offline-translate"

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/offline-translate").toString().replace(/^file:\/\//, ""))
  property var server: null
  property bool popups: true
  property bool installed: true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: stateView
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-offline-translate/state.json"
    printErrors: false
    onLoaded: {
      try { root.server = JSON.parse(text()) } catch (e) { root.server = null }
    }
    onLoadFailed: root.server = null
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: stateView.reload()
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var status = JSON.parse(text)
          root.popups = status.config.clipboardPopups !== false
          root.installed = status.installed === true
        } catch (e) {}
      }
    }
  }

  // Notice when the one-time setup finishes in its terminal.
  Timer {
    interval: 10000
    repeat: true
    running: !root.installed
    onTriggered: statusProc.running = true
  }

  Process {
    id: popupsProc
    command: [root.helper, "popups", "toggle"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.popups = text.trim() === "on"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰗊"
    active: root.server !== null
    activeColor: Commons.Color.accent
    opacity: root.popups && root.installed ? 1 : 0.55
    tooltipText: {
      if (!root.installed) return "Offline Translate\nSetup needed — click to run the one-time setup (1.4 GB download)"
      var model = !root.server ? "Model not loaded"
        : root.server.loaded === true ? "Model loaded (" + root.server.model + ") — middle-click to unload"
        : "Loading model…"
      return "Offline Translate\n" + model + "\nCopy popups: " + (root.popups ? "on" : "off") + " — right-click to toggle"
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) popupsProc.running = true
      else if (b === Qt.MiddleButton) Quickshell.execDetached([root.helper, "stop"])
      else Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "io.github.lekonidus.offline-translate", "{}"])
    }
  }
}

import QtQuick

// One plugin, two bar entries. A manifest declares a single barWidget entry
// point, so both widgets load through here and pick their role from their own
// bar entry -- the manifest sets allowMultiple, so the same id may appear
// twice in shell.json:
//
//   left:  { "id": "videinfra.tandem", "desktops": 3 }
//   right: { "id": "videinfra.tandem", "role": "settings" }
//
// Keeping them one plugin is what lets the repo have manifest.json at its
// root, which `omarchy plugin add` requires.
Item {
  id: root

  property var bar: null
  property string moduleName: ""
  property var settings: ({})

  readonly property bool isSettings:
    !!(settings && String(settings.role || "") === "settings")

  implicitWidth: loader.item ? loader.item.implicitWidth : 0
  implicitHeight: loader.item ? loader.item.implicitHeight : 0

  // The bar injects bar/moduleName/settings onto this root, which may happen
  // before or after the Loader builds its item, so forward on both edges.
  function forward() {
    var item = loader.item
    if (!item) return
    if ("bar" in item) item.bar = root.bar
    if ("moduleName" in item) item.moduleName = root.moduleName
    if ("settings" in item) item.settings = root.settings
    if ("popoutOwner" in item) item.popoutOwner = root
  }

  onBarChanged: forward()
  onModuleNameChanged: forward()
  onSettingsChanged: forward()

  // Panel-routing shape: the bar looks for these on the bar-widget root when
  // summoning or hiding a panel, and they only exist on the settings item.
  readonly property bool opened: loader.item && loader.item.opened === true
  function open() { if (loader.item && loader.item.open) loader.item.open() }
  function close() { if (loader.item && loader.item.close) loader.item.close() }
  function toggle() { if (loader.item && loader.item.toggle) loader.item.toggle() }

  // The bar draws its open-panel mark under a slot when the active popout is
  // that slot's item -- this wrapper, not the Settings panel inside it. The
  // panel registers this wrapper as its popout owner, so the wrapper also
  // answers what the bar and KeyboardPanel ask of an owner.
  readonly property bool popoutSwitchClosing:
    !!(loader.item && loader.item.popoutSwitchClosing === true)
  function closeForPopoutSwitch() {
    if (loader.item && loader.item.closeForPopoutSwitch) loader.item.closeForPopoutSwitch()
  }

  Loader {
    id: loader
    anchors.fill: parent
    sourceComponent: root.isSettings ? settingsComponent : indicatorComponent
    onLoaded: root.forward()
  }

  Component { id: indicatorComponent; Indicator {} }
  Component { id: settingsComponent; Settings {} }
}

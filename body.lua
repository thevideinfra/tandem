local COUNT = #MONITORS

local function workspace(desk, index)
  return (desk - 1) * COUNT + index
end

-- The desktop a workspace id belongs to, or nil for special workspaces and
-- anything outside the tandem range.
local function desk_of(id)
  if not id or id < 1 or id > DESKTOPS * COUNT then return nil end
  return math.floor((id - 1) / COUNT) + 1
end

local function current_desk()
  local ws = hl.get_active_workspace()
  return desk_of(ws and ws.id) or 1
end

-- The desktop every monitor is on, or nil while they are split.
local function shared_desk()
  local shared = nil
  for _, name in ipairs(MONITORS) do
    local monitor = hl.get_monitor(name)
    local ws = monitor and monitor.active_workspace
    local desk = desk_of(ws and ws.id)
    if not desk or (shared and desk ~= shared) then return nil end
    shared = desk
  end
  return shared
end

-- Self-heal after `omarchy plugin remove`: it deletes the plugin but never
-- touches Hyprland, so these bindings stay live in memory. Reload once when
-- the generated file is gone; the loader is a pcall, so the stock bindings
-- return. Checked here, not on workspace.active -- show() moves monitors with
-- set_workspace, which does not emit that event, and every binding reaches
-- show(), so the repair fires on first use of a stale one.
local SELF = (os.getenv("HOME") or "")
  .. "/.config/omarchy/plugins/videinfra.tandem/tandem.lua"
local healing = false

local function heal_if_removed()
  if healing then return false end
  local file = io.open(SELF, "r")
  if file then
    file:close()
    return false
  end
  healing = true
  hl.exec_cmd("hyprctl reload")
  return true
end

-- The desktop the monitors should all be on. Set by every switch tandem makes
-- and by the follow handler below; nil until the first one.
local desired = nil
local settling = false
local switches = 0   -- only the latest switch's timer may end settling
-- set_workspace can emit workspace.active itself when focus crosses monitors,
-- which would make the follow handler below chase tandem's own half-finished
-- switch. It ignores events while this is set.
local moving = false

-- Put any monitor that is off `desk` back on it. Monitors already there are
-- left alone, since set_workspace also moves focus.
local function realign(desk)
  moving = true
  for index, name in ipairs(MONITORS) do
    local monitor = hl.get_monitor(name)
    local ws = monitor and monitor.active_workspace
    local want = workspace(desk, index)
    if monitor and not (ws and ws.id == want) then
      monitor:set_workspace({ workspace = tostring(want) })
    end
  end
  moving = false
end

local function show(desk)
  if heal_if_removed() then return end
  desired = desk
  -- An app hidden by the switch can ask to be activated within a millisecond
  -- (a fullscreen game does), and with focus_on_activate Hyprland switches
  -- that one monitor straight back, splitting the desktops. For a moment
  -- after tandem's own switch, undo that rather than follow it.
  settling = true
  switches = switches + 1
  local this = switches
  moving = true
  for index, name in ipairs(MONITORS) do
    local monitor = hl.get_monitor(name)
    if monitor then monitor:set_workspace({ workspace = tostring(workspace(desk, index)) }) end
  end
  moving = false
  hl.timer(function() if desired then realign(desired) end end, { timeout = 150, type = "oneshot" })
  hl.timer(function()
    if desired then realign(desired) end
    if this == switches then settling = false end
  end, { timeout = 400, type = "oneshot" })
end

local function monitor_index(name)
  for index, value in ipairs(MONITORS) do
    if value == name then return index end
  end
  return nil
end

-- Send a window to the matching workspace on the monitor it is already on.
-- The window's own monitor decides the target, not whichever monitor happens
-- to be focused -- clicking on the other screen must not drag the window there.
local function send(desk, window)
  window = window or hl.get_active_window()
  local monitor = window and window.monitor
  local index = monitor and monitor_index(monitor.name)
  if index then
    hl.dispatch(hl.dsp.window.move({
      window = "address:" .. window.address,
      workspace = tostring(workspace(desk, index)),
    }))
  end
  show(desk)
end

-- Step from where the monitors actually are. If they are split, the desktop
-- tandem last switched to is the one they belong on.
local function step(offset)
  local base = shared_desk() or desired or current_desk()
  return (base - 1 + offset) % DESKTOPS + 1
end

-- Anything else that switches one monitor -- clicking an app that activates
-- itself, a notification, a stray workspace command -- brings the others to
-- the same desktop, keeping focus where it landed. The refocus comes back
-- through here too, and finds the monitors already aligned.
hl.on("workspace.active", function()
  if moving then return end
  local desk = desk_of((hl.get_active_workspace() or {}).id)
  if not desk then return end
  if settling then
    -- Undo a pull-back after the dispatch that caused it has finished;
    -- switching back from inside it gets overridden and flip-flops.
    hl.timer(function() if desired then realign(desired) end end, { timeout = 1, type = "oneshot" })
    return
  end
  if desk == desired and shared_desk() == desk then return end
  desired = desk
  local window = hl.get_active_window()
  realign(desk)
  if window then hl.dispatch(hl.dsp.focus({ window = "address:" .. window.address })) end
end)

-- Pin every workspace to its monitor so nothing drifts between screens.
for desk = 1, DESKTOPS do
  for index, name in ipairs(MONITORS) do
    hl.workspace_rule({
      workspace = tostring(workspace(desk, index)),
      monitor = name,
      default = desk == 1,
      persistent = true,
    })
  end
end

-- Omarchy's per-monitor workspace bindings move one screen at a time, which
-- would desync the desktops. Retire them before rebinding.
for id = 1, 10 do
  local key = "code:" .. tostring(id + 9)
  hl.unbind("SUPER + " .. key)
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
end
for _, key in ipairs({
  KEYS.toggle, KEYS.send,
  "SUPER + TAB", "SUPER + SHIFT + TAB", "SUPER + CTRL + TAB",
  "SUPER + mouse_down", "SUPER + mouse_up",
  "SUPER + SHIFT + ALT + LEFT", "SUPER + SHIFT + ALT + RIGHT",
  "SUPER + SHIFT + ALT + UP", "SUPER + SHIFT + ALT + DOWN",
}) do
  hl.unbind(key)
end

-- Drag-carry: SUPER+drag a window, then switch desktop to bring it along.
--
-- SUPER+scroll is a mouse bind: the pointer grab stays alive and Hyprland
-- carries the window itself, any number of desktops. That path stays a plain
-- show() -- moving the window there too would end the drag. Keyboard switches
-- drop the grab and must move it explicitly, via go().
--
-- Nothing reports the button coming up: no release event fires after a real
-- drag, and is_key_down cannot see mouse buttons. Four rules keep a stale
-- record from carrying a window nobody holds -- the record is an address,
-- re-resolved on use; the window must still be focused; focus landing
-- elsewhere clears it; the pointer must still be over it.
--
-- Do NOT re-attach with hl.dsp.window.drag() to keep the window glued to the
-- pointer: it suppresses the press that re-arms the record, giving unbounded
-- carries. Pinning (float + pin) rides every switch but needs the same
-- missing button-up to unpin, stranding the window on every desktop. See
-- NOTES.md.
local drag = nil

local function axis(value, key, index)
  if type(value) ~= "table" then return nil end
  return value[key] or value[index]
end

-- Hyprland keeps the dragged window under the pointer, so a cursor that has
-- left the window means the button came up. This is the only clear that fires
-- after a real drag: the release bind is swallowed mid-drag and reports only
-- plain clicks.
local function under_cursor(window)
  local pos = hl.get_cursor_pos()
  local at, size = window.at, window.size
  local x, y = axis(pos, "x", 1), axis(pos, "y", 2)
  local wx, wy = axis(at, "x", 1), axis(at, "y", 2)
  local ww, wh = axis(size, "x", 1), axis(size, "y", 2)
  if not (x and y and wx and wy and ww and wh) then return true end
  return x >= wx and x <= wx + ww and y >= wy and y <= wy + wh
end

local function drag_target()
  if not drag then return nil end
  local window = hl.get_window("address:" .. drag)
  if window and window.active and under_cursor(window) then return window end
  drag = nil
  return nil
end

hl.unbind("SUPER + mouse:272")
o.bind("SUPER + mouse:272", "Move window", function()
  local window = hl.get_active_window()
  drag = window and window.address or nil
  hl.dispatch(hl.dsp.window.drag())
end, { mouse = true })
o.bind("SUPER + mouse:272", nil, function() drag = nil end, { mouse = true, release = true })

-- Focus landing on a different window means the drag is over. A momentary
-- nil active window does not -- that happens mid-move, while still dragging.
hl.on("window.active", function()
  local window = hl.get_active_window()
  if window and window.address ~= drag then drag = nil end
end)

-- Switch desktop, carrying a grabbed window. Keyboard paths only; scroll must
-- not come through here. The record is consumed -- with no button-up to clear
-- it, a surviving record would carry the window again on the next switch. One
-- desktop per grab; use SUPER+scroll to go further.
local function go(desk)
  local window = drag_target()
  if not window then return show(desk) end
  drag = nil
  send(desk, window)
end

if KEYS.numbers then
  for desk = 1, math.min(DESKTOPS, 10) do
    local key = "code:" .. tostring(desk + 9)
    o.bind("SUPER + " .. key, "Desktop " .. desk, function() go(desk) end)
    o.bind("SUPER + SHIFT + " .. key, "Send window to desktop " .. desk, function() send(desk) end)
  end
end

o.bind(KEYS.toggle, "Next desktop", function() go(step(1)) end)
o.bind(KEYS.send, "Send window to next desktop", function() send(step(1)) end)

if KEYS.tab then
  o.bind("SUPER + TAB", "Next desktop", function() go(step(1)) end)
  o.bind("SUPER + SHIFT + TAB", "Previous desktop", function() go(step(-1)) end)
end

if KEYS.scroll then
  o.bind("SUPER + mouse_down", "Next desktop", function() show(step(1)) end)
  o.bind("SUPER + mouse_up", "Previous desktop", function() show(step(-1)) end)
end

-- Bridge for the bar widget. `hyprctl dispatch` evaluates the expression and
-- expects a dispatcher back, so hand it a no-op once the switch has happened.
function tandem_show(desk)
  show(desk)
  return hl.dsp.no_op()
end

-- Slide the whole desktop sideways instead of the default workspace fade.
-- Slide the whole desktop instead of the default workspace fade. "slide" moves
-- sideways and "slidevert" up and down; pick whichever matches how the
-- monitors are arranged. "none" leaves Hyprland's own workspace animation.
if ANIMATION ~= "none" then
  hl.curve("tandem", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.0 } } })
  hl.animation({ leaf = "workspaces", enabled = true, speed = 10, bezier = "tandem", style = ANIMATION })
end

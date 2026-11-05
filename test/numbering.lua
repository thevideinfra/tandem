-- Black-box test of the workspace numbering in body.lua: loads it against a
-- mocked Hyprland and checks which workspaces tandem asks each monitor to show.
--   lua5.4 test/numbering.lua
local failures, checks = 0, 0

local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print(("FAIL %s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
  end
end

local function run(opts)
  local requested = {}      -- monitor name -> last workspace asked for
  local forms = {}          -- monitor name -> "table" | "plain"
  local rules = {}          -- workspace rule ids
  local handlers = {}
  local monitors = {}

  for name, active in pairs(opts.active) do
    local monitor = { name = name, active_workspace = { id = active } }
    function monitor:set_workspace(arg)
      local id = type(arg) == "table" and arg.workspace or arg
      requested[name] = tonumber(id)
      forms[name] = type(arg) == "table" and "table" or "plain"
      -- what Hyprland does: the monitor now shows it
      self.active_workspace = { id = tonumber(id) }
    end
    monitors[name] = monitor
  end

  local env = setmetatable({
    MONITORS = opts.monitors,
    DESKTOPS = opts.desktops,
    ANIMATION = "none",
    KEYS = { toggle = "SUPER + F", send = "SUPER + SHIFT + F", numbers = false, tab = false, scroll = false },
    hl = {
      version = function() return opts.version or "0.56.2" end,
      get_monitor = function(name) return monitors[name] end,
      get_active_workspace = function() return opts.focused and { id = opts.focused } or nil end,
      get_active_window = function() return nil end,
      get_window = function() return nil end,
      get_cursor_pos = function() return {} end,
      on = function(event, fn) handlers[event] = fn end,
      timer = function(fn) fn() end,
      workspace_rule = function(rule) rules[#rules + 1] = tonumber(rule.workspace) end,
      unbind = function() end,
      dispatch = function() end,
      exec_cmd = function() end,
      curve = function() end,
      animation = function() end,
      dsp = setmetatable({}, { __index = function() return function() return {} end end }),
    },
    o = {
      bind = function() end,
      window = function() end,
      workspaces = opts.blocks and {
        workspace_id = function(monitor, slot) return opts.blocks[monitor.name] * 10 + slot end,
      } or nil,
    },
  }, { __index = _G })
  env.hl.dsp.window = setmetatable({}, { __index = function() return function() return {} end end })

  local chunk = assert(loadfile("body.lua", "t", env))
  chunk()
  return { env = env, requested = requested, forms = forms, rules = rules, handlers = handlers, monitors = monitors }
end

-- 1. Before Omarchy 4.5: desktops interleave, DP-1 odd and DP-3 even.
do
  local r = run({ monitors = { "DP-1", "DP-3" }, desktops = 2, active = { ["DP-1"] = 1, ["DP-3"] = 2 } })
  r.env.tandem_show(2)
  eq(r.requested["DP-1"], 3, "interleaved: DP-1 on desktop 2")
  eq(r.requested["DP-3"], 4, "interleaved: DP-3 on desktop 2")
  eq(r.forms["DP-1"], "table", "0.56 uses the table form")
end

-- 2. Omarchy 4.5: each monitor owns a block of ten, desktop N is slot N.
do
  local r = run({ monitors = { "DP-1", "DP-3" }, desktops = 2, blocks = { ["DP-1"] = 0, ["DP-3"] = 1 },
    active = { ["DP-1"] = 1, ["DP-3"] = 11 } })
  r.env.tandem_show(2)
  eq(r.requested["DP-1"], 2, "blocks: DP-1 on desktop 2")
  eq(r.requested["DP-3"], 12, "blocks: DP-3 on desktop 2")
  local pinned = {}
  for _, id in ipairs(r.rules) do pinned[id] = true end
  eq(pinned[1] and pinned[2] and pinned[11] and pinned[12], true, "blocks: rules pin 1 2 11 12")
  eq(pinned[3] or pinned[4], nil, "blocks: no interleaved rules")
end

-- 3. Blocks follow the physical monitor, not Tandem's order.
do
  local r = run({ monitors = { "DP-1", "DP-3" }, desktops = 2, blocks = { ["DP-1"] = 1, ["DP-3"] = 0 },
    active = { ["DP-1"] = 11, ["DP-3"] = 1 } })
  r.env.tandem_show(2)
  eq(r.requested["DP-1"], 12, "swapped blocks: DP-1")
  eq(r.requested["DP-3"], 2, "swapped blocks: DP-3")
end

-- 4. A split state is brought together: DP-1 on 1, DP-3 on 12 means desktop 2.
do
  local r = run({ monitors = { "DP-1", "DP-3" }, desktops = 2, blocks = { ["DP-1"] = 0, ["DP-3"] = 1 },
    active = { ["DP-1"] = 1, ["DP-3"] = 12 }, focused = 12 })
  r.handlers["workspace.active"]()
  eq(r.requested["DP-1"], 2, "follow: DP-1 pulled to desktop 2")
  eq(r.requested["DP-3"], nil, "follow: DP-3 left alone")
end

-- 5. A monitor sitting in the other monitor's block is not on its desktop.
do
  local r = run({ monitors = { "DP-1", "DP-3" }, desktops = 2, blocks = { ["DP-1"] = 0, ["DP-3"] = 1 },
    active = { ["DP-1"] = 2, ["DP-3"] = 2 }, focused = 2 })
  r.handlers["workspace.active"]()
  eq(r.requested["DP-3"], 12, "foreign block: DP-3 returned to its own slot")
end

-- 6. 0.57 takes the plain selector.
do
  local r = run({ monitors = { "DP-1", "DP-3" }, desktops = 2, blocks = { ["DP-1"] = 0, ["DP-3"] = 1 },
    active = { ["DP-1"] = 1, ["DP-3"] = 11 }, version = "0.57.0" })
  r.env.tandem_show(2)
  eq(r.forms["DP-3"], "plain", "0.57 uses the plain selector")
end

print(("%d checks, %d failed"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)

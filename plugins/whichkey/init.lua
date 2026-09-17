-- mod-version:4
--
-- which-key — show available key continuations after a prefix is pressed.
--
-- After `config.plugins.whichkey.delay` seconds with a prefix pending
-- (e.g. ctrl+c, ctrl+x), a floating panel appears above the status bar
-- listing every bound continuation and what it does.
--
-- Commands:
--   whichkey:toggle  — toggle between delay=0 (always-on) and delay=0.5s

local core    = require "core"
local common  = require "core.common"
local command = require "core.command"
local config  = require "core.config"
local keymap  = require "core.keymap"
local style   = require "core.style"

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

config.plugins.whichkey = common.merge({
  delay          = 0.5,  -- seconds before popup appears; set to 0 for immediate
  col_width      = 280,  -- per-column pixel width; scaled by the live SCALE at draw time (popup.lua)
  max_desc_lines = 2,    -- wrap a long description onto at most this many lines
}, config.plugins.whichkey)

-- ---------------------------------------------------------------------------
-- Shared state (popup.lua reads this during draw)
-- ---------------------------------------------------------------------------

local state = {
  visible = false,
  prefix  = nil,   -- e.g. "ctrl+c"
  entries = {},    -- array of { key, display, is_prefix }
  show_id = 0,     -- incremented on each new schedule; stale timers bail early
}

-- ---------------------------------------------------------------------------
-- Entry builder
-- ---------------------------------------------------------------------------

-- Return all one-step continuations of `prefix` found in keymap.map, sorted.
local function get_entries(prefix)
  local seen   = {}  -- next_stroke → first command name string
  local is_pfx = {}  -- next_stroke → true when it leads to further bindings

  local pfx = prefix .. " "
  for seq, cmds in pairs(keymap.map) do
    if seq:sub(1, #pfx) == pfx then
      local rest        = seq:sub(#pfx + 1)
      local next_stroke = rest:match("^([^ ]+)") or rest
      if not seen[next_stroke] then
        local cmd = type(cmds) == "table" and cmds[1] or cmds
        seen[next_stroke] = type(cmd) == "string" and cmd or "(fn)"
      end
      -- If there is a space after the first stroke, the sequence is longer,
      -- meaning next_stroke is itself a prefix for more bindings.
      if rest:find(" ", 1, true) then
        is_pfx[next_stroke] = true
      end
    end
  end

  local entries = {}
  for k, cmd in pairs(seen) do
    local display = is_pfx[k] and ("+" .. cmd) or cmd
    table.insert(entries, {
      key       = k,
      display   = display,
      is_prefix = is_pfx[k] or false,
    })
  end

  table.sort(entries, function(a, b) return a.key < b.key end)
  return entries
end

-- ---------------------------------------------------------------------------
-- keymap.on_key_pressed wrapper
-- ---------------------------------------------------------------------------

local original_on_key_pressed = keymap.on_key_pressed

function keymap.on_key_pressed(k, ...)
  local result = original_on_key_pressed(k, ...)

  if keymap.pending_prefix then
    -- A prefix is now pending (new or extended).  Schedule the popup.
    local id     = state.show_id + 1
    state.show_id = id
    state.visible = false   -- hide any currently visible popup immediately
    core.redraw   = true
    local prefix  = keymap.pending_prefix

    core.add_thread(function()
      local delay = config.plugins.whichkey.delay
      local t0    = system.get_time()
      while system.get_time() - t0 < delay do
        coroutine.yield()
      end
      -- Only show if the same prefix is still pending.
      if state.show_id == id and keymap.pending_prefix == prefix then
        state.prefix  = prefix
        state.entries = get_entries(prefix)
        state.visible = true
        core.redraw   = true
      end
    end)
  else
    -- Prefix was completed or cancelled: hide the popup.
    if state.visible or state.show_id > 0 then
      state.visible  = false
      state.show_id  = state.show_id + 1   -- cancels any pending timer
      core.redraw    = true
    end
  end

  return result
end

-- ---------------------------------------------------------------------------
-- RootView.draw hook — draw popup on top of everything
-- ---------------------------------------------------------------------------

local RootView = require "core.rootview"
local popup    = require "plugins.whichkey.popup"

local old_draw = RootView.draw
function RootView:draw()
  old_draw(self)
  if state.visible and #state.entries > 0 then
    popup.draw(self, state)
  end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- Toggle: switch between delay=0 (popup always shows immediately on prefix)
-- and the configured delay (default 0.5 s).
local _saved_delay = config.plugins.whichkey.delay

command.add(nil, {
  ["whichkey:toggle"] = function()
    if config.plugins.whichkey.delay > 0 then
      _saved_delay = config.plugins.whichkey.delay
      config.plugins.whichkey.delay = 0
      core.log("which-key: always-on (delay = 0)")
    else
      config.plugins.whichkey.delay = _saved_delay > 0 and _saved_delay or 0.5
      core.log("which-key: delay = %.1f s", config.plugins.whichkey.delay)
    end
  end,
})

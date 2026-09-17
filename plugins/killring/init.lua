-- mod-version:4
--
-- killring — Emacs-style kill-ring / clipboard history.
--
-- Every copy or cut inside Lite-XL (and text copied outside when the view
-- is opened) is pushed onto a ring capped at MAX_RING entries.
--
-- Default bindings:
--   alt+y          open / focus the Kill Ring panel
--   up / down      navigate (also ctrl+p / ctrl+n via keymap/init.lua)
--   return         paste selected entry into the source buffer
--   (typing)       fuzzy filter
--   ctrl+shift+k   clear the entire ring (in KillRingView)

local core          = require "core"
local common        = require "core.common"
local config        = require "core.config"
local command       = require "core.command"
local DocView       = require "core.docview"
local ListView      = require "plugins.shared.listview"
local KillRingView  = require "plugins.killring.killringview"

config.plugins.killring = common.merge({
  max_entries = 100,  -- maximum number of entries kept in the ring
}, config.plugins.killring)

-- ---------------------------------------------------------------------------
-- Ring state
-- ---------------------------------------------------------------------------

local ring = {}

local function push_ring(text)
  if not text or text == "" then return end
  for i, v in ipairs(ring) do
    if v == text then table.remove(ring, i); break end
  end
  table.insert(ring, 1, text)
  if #ring > config.plugins.killring.max_entries then
    ring[config.plugins.killring.max_entries + 1] = nil
  end
end

-- ---------------------------------------------------------------------------
-- Hook system.set_clipboard so every copy/cut is captured automatically.
-- ---------------------------------------------------------------------------

local orig_set_clipboard = system.set_clipboard
system.set_clipboard = function(text)
  orig_set_clipboard(text)
  push_ring(text)
end

-- ---------------------------------------------------------------------------
-- Open / focus the KillRingView
-- ---------------------------------------------------------------------------

local function open_killring()
  -- Sync: if the system clipboard has changed since the last copy inside
  -- Lite-XL (e.g. copied in another app), prepend it to the ring.
  local sys = system.get_clipboard()
  if sys and sys ~= "" and sys ~= ring[1] then
    push_ring(sys)
  end

  -- Save the current DocView as the paste target.
  local av = core.active_view
  local target = (av and av:is(DocView)) and av or nil

  local existing = ListView.find_overlay_view(KillRingView)
  if existing then
    existing.target_view = target
    existing:populate()
    existing:open_as_overlay()
    return
  end
  KillRingView(target, ring):open_as_overlay()
end

-- ---------------------------------------------------------------------------
-- Proxy helper — routes standard doc:* commands to the embedded filter editor.
-- ---------------------------------------------------------------------------

local function with_filter(fn)
  return function(v)
    local prev = core.active_view
    core.active_view = v.filter_view
    fn()
    core.active_view = prev
  end
end

-- ---------------------------------------------------------------------------
-- Global command
-- ---------------------------------------------------------------------------

command.add(nil, {
  ["killring:open"] = open_killring,
})

-- ---------------------------------------------------------------------------
-- Commands scoped to KillRingView
-- ---------------------------------------------------------------------------

command.add(KillRingView, {
  -- Navigation
  ["killring:select-previous"] = function(v)
    v.selected_idx = math.max(v.selected_idx - 1, 1)
    v:scroll_to_make_selected_visible()
  end,

  ["killring:select-next"] = function(v)
    v.selected_idx = math.min(v.selected_idx + 1, #v.filtered_results)
    v:scroll_to_make_selected_visible()
  end,

  ["killring:paste-selected"] = function(v)
    if v:open_selected() then v:close() end
  end,

  ["killring:clear"] = function(v)
    for i = #ring, 1, -1 do ring[i] = nil end
    v:populate()
  end,

  -- Deletion
  ["killring:backspace"]            = with_filter(function() command.perform("doc:backspace") end),
  ["killring:delete-word-backward"] = with_filter(function() command.perform("doc:delete-to-previous-word-start") end),
  ["killring:delete-forward"]       = with_filter(function() command.perform("doc:delete") end),
  ["killring:delete-word-forward"]  = with_filter(function() command.perform("doc:delete-to-next-word-end") end),

  -- Cursor movement
  ["killring:move-left"]       = with_filter(function() command.perform("doc:move-to-previous-char") end),
  ["killring:move-right"]      = with_filter(function() command.perform("doc:move-to-next-char") end),
  ["killring:move-word-left"]  = with_filter(function() command.perform("doc:move-to-previous-word-start") end),
  ["killring:move-word-right"] = with_filter(function() command.perform("doc:move-to-next-word-end") end),
  ["killring:move-home"]       = with_filter(function() command.perform("doc:move-to-start-of-indentation") end),
  ["killring:move-end"]        = with_filter(function() command.perform("doc:move-to-end-of-line") end),

  -- Selection
  ["killring:select-to-left"]       = with_filter(function() command.perform("doc:select-to-previous-char") end),
  ["killring:select-to-right"]      = with_filter(function() command.perform("doc:select-to-next-char") end),
  ["killring:select-to-word-left"]  = with_filter(function() command.perform("doc:select-to-previous-word-start") end),
  ["killring:select-to-word-right"] = with_filter(function() command.perform("doc:select-to-next-word-end") end),
  ["killring:select-to-home"]       = with_filter(function() command.perform("doc:select-to-start-of-indentation") end),
  ["killring:select-to-end"]        = with_filter(function() command.perform("doc:select-to-end-of-line") end),

  -- Clipboard / undo
  ["killring:cut"]   = with_filter(function() command.perform("doc:cut") end),
  ["killring:paste"] = with_filter(function() command.perform("doc:paste") end),
  ["killring:undo"]  = with_filter(function() command.perform("doc:undo") end),
  ["killring:redo"]  = with_filter(function() command.perform("doc:redo") end),
})

-- killring:clear-filter fires only when filter text is non-empty.
command.add(function()
  local v = core.active_view
  if not v:is(KillRingView) then return false end
  local text = v.filter_doc:get_text(1, 1, 1, math.huge)
  return text ~= "", v
end, {
  ["killring:clear-filter"] = function(v)
    v.filter_doc:remove(1, 1, math.huge, math.huge)
    v:update_filter(true)
  end,
})

-- Keybindings are centralized in configs/keymap/init.lua.

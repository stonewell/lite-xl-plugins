-- mod-version:4
local core     = require "core"
local command  = require "core.command"
local ListView = require "plugins.shared.listview"
local H        = require "plugins.shared.search_helpers"
local FdView   = require "plugins.fd-files.fdview"

-- ---------------------------------------------------------------------------
-- Open or reuse existing FdView overlay
-- ---------------------------------------------------------------------------

local function open_fd_view(root)
  local existing = ListView.find_overlay_view(FdView)
  if existing then
    existing.root = root
    existing:begin_search()
    existing:open_as_overlay()
    return
  end
  FdView(root):open_as_overlay()
end

-- ---------------------------------------------------------------------------
-- Proxy helper: temporarily make filter_view the active view so that
-- standard doc commands operate on filter_doc rather than nothing.
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
-- Commands
-- ---------------------------------------------------------------------------

command.add(nil, {
  ["fd-files:find"] = function()
    open_fd_view(H.get_search_root())
  end,
})

command.add(FdView, {
  ["fd-files:select-previous"] = function(v)
    v.selected_idx = math.max(v.selected_idx - 1, 1)
    v:scroll_to_make_selected_visible()
  end,

  ["fd-files:select-next"] = function(v)
    v.selected_idx = math.min(v.selected_idx + 1, #v.filtered_results)
    v:scroll_to_make_selected_visible()
  end,

  ["fd-files:open-selected"] = function(v)
    if v:open_selected() then v:close() end
  end,

  ["fd-files:refresh"] = function(v)
    v:refresh()
  end,

  -- Deletion
  ["fd-files:backspace"]            = with_filter(function() command.perform("doc:backspace") end),
  ["fd-files:delete-word-backward"] = with_filter(function() command.perform("doc:delete-to-previous-word-start") end),
  ["fd-files:delete-forward"]       = with_filter(function() command.perform("doc:delete") end),
  ["fd-files:delete-word-forward"]  = with_filter(function() command.perform("doc:delete-to-next-word-end") end),

  -- Cursor movement
  ["fd-files:move-left"]       = with_filter(function() command.perform("doc:move-to-previous-char") end),
  ["fd-files:move-right"]      = with_filter(function() command.perform("doc:move-to-next-char") end),
  ["fd-files:move-word-left"]  = with_filter(function() command.perform("doc:move-to-previous-word-start") end),
  ["fd-files:move-word-right"] = with_filter(function() command.perform("doc:move-to-next-word-end") end),
  ["fd-files:move-home"]       = with_filter(function() command.perform("doc:move-to-start-of-indentation") end),
  ["fd-files:move-end"]        = with_filter(function() command.perform("doc:move-to-end-of-line") end),

  -- Selection
  ["fd-files:select-to-left"]       = with_filter(function() command.perform("doc:select-to-previous-char") end),
  ["fd-files:select-to-right"]      = with_filter(function() command.perform("doc:select-to-next-char") end),
  ["fd-files:select-to-word-left"]  = with_filter(function() command.perform("doc:select-to-previous-word-start") end),
  ["fd-files:select-to-word-right"] = with_filter(function() command.perform("doc:select-to-next-word-end") end),
  ["fd-files:select-to-home"]       = with_filter(function() command.perform("doc:select-to-start-of-indentation") end),
  ["fd-files:select-to-end"]        = with_filter(function() command.perform("doc:select-to-end-of-line") end),

  -- Clipboard / undo
  ["fd-files:cut"]   = with_filter(function() command.perform("doc:cut") end),
  ["fd-files:paste"] = with_filter(function() command.perform("doc:paste") end),
  ["fd-files:undo"]  = with_filter(function() command.perform("doc:undo") end),
  ["fd-files:redo"]  = with_filter(function() command.perform("doc:redo") end),
})

-- fd-files:clear-filter only fires (and consumes the key) when there is
-- actually text to clear.
command.add(function()
  local v = core.active_view
  if not v:extends(FdView) then return false end
  local text = v.filter_doc:get_text(1, 1, 1, math.huge)
  return text ~= "", v
end, {
  ["fd-files:clear-filter"] = function(v)
    v.filter_doc:remove(1, 1, math.huge, math.huge)
    v:update_filter(true)
  end,
})

-- Keybindings are centralized in configs/keymap/init.lua.

-- mod-version:4
local core      = require "core"
local command   = require "core.command"
local ListView  = require "plugins.shared.listview"
local H         = require "plugins.shared.search_helpers"
local RgView    = require "plugins.rgsearch.rgview"

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

local history = {}

local function push_history(query)
  for i, v in ipairs(history) do
    if v == query then table.remove(history, i) break end
  end
  table.insert(history, 1, query)
  if #history > 50 then history[51] = nil end
end

local function history_suggestions(text)
  local t = {}
  for _, v in ipairs(history) do
    if text == "" or v:find(text, 1, true) then
      table.insert(t, { text = v })
    end
  end
  return t
end

-- ---------------------------------------------------------------------------
-- Open or reuse existing RgView in the active node
-- ---------------------------------------------------------------------------

local function open_rg_view(query, root)
  local existing = ListView.find_overlay_view(RgView)
  if existing then
    existing.root = root
    existing:begin_search(query)
    existing:open_as_overlay()
    return
  end
  RgView(query, root):open_as_overlay()
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
  ["rg-search:find"] = function()
    local preselect = H.get_selection_or_word()
    local root = H.get_search_root()
    core.command_view:enter("Rg Search", {
      text         = preselect,
      select_text  = preselect ~= "",
      suggest      = history_suggestions,
      submit       = function(text)
        if text == "" then return end
        push_history(text)
        open_rg_view(text, root)
      end,
    })
  end,

  ["rg-search:find-at-caret"] = function()
    local word = H.get_selection_or_word()
    if word == "" then
      core.warn("rg-search: no word under caret")
      return
    end
    push_history(word)
    open_rg_view(word, H.get_search_root())
  end,
})

command.add(RgView, {
  ["rg-search:select-previous"] = function(v)
    v.selected_idx = math.max(v.selected_idx - 1, 1)
    v:scroll_to_make_selected_visible()
  end,

  ["rg-search:select-next"] = function(v)
    v.selected_idx = math.min(v.selected_idx + 1, #v.filtered_results)
    v:scroll_to_make_selected_visible()
  end,

  ["rg-search:open-selected"] = function(v)
    if v:open_selected_result() then v:close() end
  end,

  ["rg-search:refresh"] = function(v)
    v:refresh()
  end,

  -- Deletion
  ["rg-search:backspace"]           = with_filter(function() command.perform("doc:backspace") end),
  ["rg-search:delete-word-backward"]= with_filter(function() command.perform("doc:delete-to-previous-word-start") end),
  ["rg-search:delete-forward"]      = with_filter(function() command.perform("doc:delete") end),
  ["rg-search:delete-word-forward"] = with_filter(function() command.perform("doc:delete-to-next-word-end") end),

  -- Cursor movement
  ["rg-search:move-left"]      = with_filter(function() command.perform("doc:move-to-previous-char") end),
  ["rg-search:move-right"]     = with_filter(function() command.perform("doc:move-to-next-char") end),
  ["rg-search:move-word-left"] = with_filter(function() command.perform("doc:move-to-previous-word-start") end),
  ["rg-search:move-word-right"]= with_filter(function() command.perform("doc:move-to-next-word-end") end),
  ["rg-search:move-home"]      = with_filter(function() command.perform("doc:move-to-start-of-indentation") end),
  ["rg-search:move-end"]       = with_filter(function() command.perform("doc:move-to-end-of-line") end),

  -- Selection
  ["rg-search:select-to-left"]      = with_filter(function() command.perform("doc:select-to-previous-char") end),
  ["rg-search:select-to-right"]     = with_filter(function() command.perform("doc:select-to-next-char") end),
  ["rg-search:select-to-word-left"] = with_filter(function() command.perform("doc:select-to-previous-word-start") end),
  ["rg-search:select-to-word-right"]= with_filter(function() command.perform("doc:select-to-next-word-end") end),
  ["rg-search:select-to-home"]      = with_filter(function() command.perform("doc:select-to-start-of-indentation") end),
  ["rg-search:select-to-end"]       = with_filter(function() command.perform("doc:select-to-end-of-line") end),

  -- Clipboard / undo
  ["rg-search:cut"]   = with_filter(function() command.perform("doc:cut") end),
  ["rg-search:paste"] = with_filter(function() command.perform("doc:paste") end),
  ["rg-search:undo"]  = with_filter(function() command.perform("doc:undo") end),
  ["rg-search:redo"]  = with_filter(function() command.perform("doc:redo") end),
})

-- rg-search:clear-filter has a non-empty predicate so it only fires (and
-- consumes the key) when there is actually text to clear.
command.add(function()
  local v = core.active_view
  if not v:extends(RgView) then return false end
  local text = v.filter_doc:get_text(1, 1, 1, math.huge)
  return text ~= "", v
end, {
  ["rg-search:clear-filter"] = function(v)
    v.filter_doc:remove(1, 1, math.huge, math.huge)
    v:update_filter(true)
  end,
})

-- Keybindings are centralized in configs/keymap/init.lua.

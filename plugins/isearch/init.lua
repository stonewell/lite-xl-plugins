-- mod-version:4
--
-- Emacs-style incremental search with live multi-match highlighting.
--
-- Bindings (can be rebound):
--   ctrl+s   isearch:forward        -- start / advance forward
--   ctrl+r   isearch:backward       -- start / advance backward
--   ctrl+g   isearch:cancel         -- cancel, restore original position
--   ctrl+w   isearch:extend-word    -- yank word at match into query
--   alt+c    isearch:toggle-case    -- toggle case sensitivity
--   return   isearch:confirm        -- keep cursor at current match
--   backspace                       -- delete last char from query
--   (any printable char)            -- extend query
--   (any other key)                 -- confirm then execute the key normally

local core    = require "core"
local command = require "core.command"
local config  = require "core.config"
local keymap  = require "core.keymap"
local search  = require "core.doc.search"
local state   = require "plugins.isearch.highlight"

local macos      = PLATFORM == "Mac OS X"
local modkey_map = require("core.modkeys-" .. (macos and "macos" or "generic")).map

local MODKEY_ORDER = { "ctrl", "shift", "alt", "altgr", "super" }

local function current_stroke(k)
  local parts = {}
  for _, mod in ipairs(MODKEY_ORDER) do
    if keymap.modkeys[mod] then table.insert(parts, mod) end
  end
  table.insert(parts, k)
  return table.concat(parts, "+")
end

local function stroke_matches(stroke, cmd_name)
  for _, b in ipairs(keymap.get_bindings(cmd_name) or {}) do
    if b == stroke then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

local function update_status(failing, wrapped)
  local dir = state.direction == "backward" and " backward" or ""
  local cs  = state.case_sensitive and " [case]" or ""
  local pfx = failing   and ("Failing I-search" .. dir)
             or wrapped and ("Wrapped I-search" .. dir)
             or           ("I-search" .. dir)
  core.status_view:show_tooltip(pfx .. cs .. ": " .. state.query)
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Wrap detection helpers
-- ---------------------------------------------------------------------------

local function did_wrap_forward(from_l, from_c, l1, c1)
  return l1 < from_l or (l1 == from_l and c1 < from_c)
end

local function did_wrap_backward(from_l, from_c, l1, c1)
  return l1 > from_l or (l1 == from_l and c1 > from_c)
end

-- ---------------------------------------------------------------------------
-- Search helpers
-- ---------------------------------------------------------------------------

local function do_find(from_l, from_c, dir)
  return search.find(
    state.view.doc, from_l, from_c, state.query,
    { wrap = true, no_case = not state.case_sensitive, reverse = dir == "backward" }
  )
end

local function apply_match(l1, c1, l2, c2)
  state.match = { l1, c1, l2, c2 }
  state.view.doc:set_selection(l2, c2, l1, c1)
  state.view:scroll_to_make_visible(l2, c2)
end

-- Re-search from origin whenever the query changes.
local function update_search()
  if state.query == "" then
    state.match = nil
    state.view.doc:set_selection(table.unpack(state.origin))
    update_status(false, false)
    return
  end
  local l1, c1, l2, c2 = do_find(state.origin[1], state.origin[2], state.direction)
  if l1 then
    apply_match(l1, c1, l2, c2)
    update_status(false, false)
  else
    state.match = nil
    state.view.doc:set_selection(table.unpack(state.origin))
    update_status(true, false)
  end
end

-- Advance to the next / previous occurrence from the current match position.
local function advance_search(dir)
  state.direction = dir
  if not state.match or state.query == "" then
    update_search()
    return
  end
  -- For forward: start after the end of the current match.
  -- For backward: start before the beginning of the current match.
  local from_l = dir == "forward" and state.match[3] or state.match[1]
  local from_c = dir == "forward" and state.match[4] or state.match[2]
  local l1, c1, l2, c2 = do_find(from_l, from_c, dir)
  if l1 then
    local wrapped = dir == "forward"
      and did_wrap_forward(from_l, from_c, l1, c1)
      or  did_wrap_backward(from_l, from_c, l1, c1)
    apply_match(l1, c1, l2, c2)
    update_status(false, wrapped)
  else
    update_status(true, false)
  end
end

-- ---------------------------------------------------------------------------
-- Session management
-- ---------------------------------------------------------------------------

local function isearch_confirm()
  state.active = false
  state.match  = nil
  core.status_view:remove_tooltip()
  core.redraw = true
end

local function isearch_cancel()
  if state.view and state.origin then
    state.view.doc:set_selection(table.unpack(state.origin))
    state.view:scroll_to_make_visible(state.origin[1], state.origin[2])
  end
  state.active = false
  state.match  = nil
  core.status_view:remove_tooltip()
  core.redraw = true
end

local function isearch_start(dir, dv)
  state.direction      = dir
  state.view           = dv
  state.active         = true
  state.match          = nil
  state.case_sensitive = config.plugins.isearch.case_sensitive
  -- Seed query from current selection, or start empty.
  local l1, c1, l2, c2 = dv.doc:get_selection()
  if l1 == l2 and c1 == c2 then
    state.query  = ""
    state.origin = { l1, c1, l1, c1 }
  else
    state.query  = dv.doc:get_text(l1, c1, l2, c2)
    state.origin = { l1, c1, l2, c2 }
  end
  update_search()
end

-- Yank the non-whitespace run starting at col into the query.
local function extend_word()
  local doc   = state.view.doc
  local line  = state.match and state.match[3] or state.origin[1]
  local col   = state.match and state.match[4] or state.origin[2]
  local text  = doc.lines[line] or ""
  local word  = (text:match("^(%S+)", col) or ""):gsub("\n", "")
  if word ~= "" then
    state.query = state.query .. word
    update_search()
  end
end

-- ---------------------------------------------------------------------------
-- keymap.on_key_pressed wrapper
-- ---------------------------------------------------------------------------

local original_on_key_pressed = keymap.on_key_pressed

function keymap.on_key_pressed(k, ...)
  if not state.active then
    return original_on_key_pressed(k, ...)
  end

  -- Auto-cancel if the user switched to a different view.
  if core.active_view ~= state.view then
    isearch_cancel()
    return original_on_key_pressed(k, ...)
  end

  -- Modifier-only presses update keymap.modkeys but don't affect the search.
  if modkey_map[k] then
    return original_on_key_pressed(k, ...)
  end

  local stroke = current_stroke(k)

  -- isearch navigation.
  if stroke_matches(stroke, "isearch:forward") then
    advance_search("forward")
    return true
  end
  if stroke_matches(stroke, "isearch:backward") then
    advance_search("backward")
    return true
  end
  -- Cancel: restore original position.
  if stroke_matches(stroke, "isearch:cancel") then
    isearch_cancel()
    return true
  end

  -- Backspace: remove last UTF-8 character from query.
  if k == "backspace" then
    state.query = state.query:gsub("[%z\1-\x7F\xC2-\xFD][\x80-\xBF]*$", "")
    update_search()
    return true
  end

  -- Enter: confirm, stay at match, don't insert a newline.
  if k == "return" or k == "keypad enter" then
    isearch_confirm()
    return true
  end

  -- ctrl+w: yank word at match position into query.
  if stroke_matches(stroke, "isearch:extend-word") then
    extend_word()
    return true
  end

  -- alt+c: toggle case sensitivity.
  if stroke_matches(stroke, "isearch:toggle-case") then
    state.case_sensitive = not state.case_sensitive
    update_search()
    return true
  end

  -- Printable character: no direct binding, no modifier held → let the
  -- subsequent textinput event append it to the query (see core.on_event).
  local has_binding = keymap.map[stroke] ~= nil
  local has_modifier = keymap.modkeys["ctrl"] or keymap.modkeys["alt"]
    or keymap.modkeys["super"] or keymap.modkeys["altgr"]

  if not has_binding and not has_modifier then
    return false  -- did_keymap stays false → textinput fires → appends to query
  end

  -- Any other key with a binding or modifier: confirm then execute normally.
  isearch_confirm()
  return original_on_key_pressed(k, ...)
end

-- ---------------------------------------------------------------------------
-- core.on_event wrapper — captures textinput to extend the query
-- ---------------------------------------------------------------------------

local original_on_event = core.on_event

core.on_event = function(type, ...)
  if state.active and type == "textinput" then
    state.query = state.query .. (...)
    update_search()
    return true
  end
  return original_on_event(type, ...)
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- isearch:forward / backward are strict-DocView so they don't fire when the
-- CommandView is active (find-replace commands can still reach it there).
command.add("core.docview!", {
  ["isearch:forward"]  = function(dv) isearch_start("forward",  dv) end,
  ["isearch:backward"] = function(dv) isearch_start("backward", dv) end,
})

-- The remaining commands only succeed when isearch is active, so their keys
-- fall through to their normal bindings when isearch is idle.
command.add(function() return state.active end, {
  ["isearch:cancel"]      = isearch_cancel,
  ["isearch:confirm"]     = isearch_confirm,
  ["isearch:extend-word"] = extend_word,
  ["isearch:toggle-case"] = function()
    state.case_sensitive = not state.case_sensitive
    update_search()
  end,
})

-- Keybindings are centralized in configs/keymap/init.lua.

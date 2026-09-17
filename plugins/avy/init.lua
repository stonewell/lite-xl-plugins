-- mod-version:4
--
-- Avy-style jump-to-char/word/line with label overlays.
--
-- Default bindings:
--   ctrl+;       avy:goto-char    type 1 char, jump to any visible match
--   ctrl+'       avy:goto-char-2  type 2 chars for fewer, more precise matches
--   ctrl+c j w   avy:goto-word    label every visible word start
--   ctrl+c j l   avy:goto-line    label every visible line
--   ctrl+g / escape  cancel

local core    = require "core"
local command = require "core.command"
local config  = require "core.config"
local keymap  = require "core.keymap"
local state   = require "plugins.avy.overlay"

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
-- Candidate finders
-- ---------------------------------------------------------------------------

-- All byte-positions of query string in visible lines (case-insensitive).
local function find_char_candidates(dv, query)
  local min, max = dv:get_visible_line_range()
  local q   = query:lower()
  local res = {}
  for line = min, max do
    local text = dv.doc.lines[line]:lower()
    local col  = 1
    while true do
      local s = text:find(q, col, true)
      if not s then break end
      table.insert(res, { line = line, col = s })
      col = s + 1
    end
  end
  return res
end

-- First character of every non-whitespace run on visible lines.
local function find_word_candidates(dv)
  local min, max = dv:get_visible_line_range()
  local res = {}
  for line = min, max do
    local text = dv.doc.lines[line]
    local col  = 1
    while true do
      local s, e = text:find("%S+", col)
      if not s then break end
      table.insert(res, { line = line, col = s })
      col = e + 1
    end
  end
  return res
end

-- First non-whitespace column of every visible line.
local function find_line_candidates(dv)
  local min, max = dv:get_visible_line_range()
  local res = {}
  for line = min, max do
    local col = dv.doc.lines[line]:match("^%s*()") or 1
    table.insert(res, { line = line, col = col })
  end
  return res
end

-- ---------------------------------------------------------------------------
-- Label assignment
-- ---------------------------------------------------------------------------

local function assign_labels(candidates)
  local keys = config.plugins.avy.keys
  local nk   = #keys
  local n    = #candidates
  for i, c in ipairs(candidates) do
    if n <= nk then
      c.label = keys:sub(i, i)
    else
      -- 2-char labels: outer index selects group key, inner selects within group.
      local g = math.ceil(i / nk)
      local s = ((i - 1) % nk) + 1
      -- Guard: if g > nk we've exceeded the 2-char label space (nk^2 entries).
      -- This is only possible with > 676 visible candidates; fall back to numbers.
      if g > nk then
        c.label = tostring(i)
      else
        c.label = keys:sub(g, g) .. keys:sub(s, s)
      end
    end
  end
end

-- Build a reverse map: label_string → candidate (for exact matches) and
-- a set of valid prefixes (for partial matching).
local function build_label_map(candidates)
  local exact   = {}
  local prefixes = {}
  for _, c in ipairs(candidates) do
    exact[c.label] = c
    if #c.label == 2 then
      prefixes[c.label:sub(1, 1)] = true
    end
  end
  return exact, prefixes
end

-- ---------------------------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------------------------

local label_exact   = {}
local label_prefix  = {}

local function avy_reset()
  state.active      = false
  state.phase       = "idle"
  state.mode        = nil
  state.view        = nil
  state.query       = ""
  state.query_len   = 1
  state.candidates  = {}
  state.label_input = ""
  label_exact       = {}
  label_prefix      = {}
end

local function avy_cancel()
  avy_reset()
  core.status_view:remove_tooltip()
  core.redraw = true
end

local function jump_to(c)
  local dv = state.view
  dv.doc:set_selection(c.line, c.col)
  dv:scroll_to_make_visible(c.line, c.col)
end

local function update_status()
  local prompt
  if state.phase == "input" then
    local remaining = state.query_len - #state.query
    prompt = string.format("avy [%s]: type %d char%s to search",
      state.mode, remaining, remaining == 1 and "" or "s")
  else
    local nlabels = #state.candidates
    if state.label_input == "" then
      prompt = string.format("avy: %d candidates — type label to jump", nlabels)
    else
      prompt = string.format("avy: prefix %q — type next label char", state.label_input)
    end
  end
  core.status_view:show_tooltip(prompt)
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Transition: input phase complete → find candidates → enter select phase
-- ---------------------------------------------------------------------------

local function find_and_enter_select()
  local dv   = state.view
  local mode = state.mode
  local cands

  if mode == "char" then
    cands = find_char_candidates(dv, state.query)
  elseif mode == "word" then
    cands = find_word_candidates(dv)
  else -- "line"
    cands = find_line_candidates(dv)
  end

  if #cands == 0 then
    core.status_view:show_tooltip("avy: no matches")
    core.redraw = true
    avy_reset()
    -- Keep tooltip visible briefly then clear.
    core.add_thread(function()
      coroutine.yield(1.5)
      core.status_view:remove_tooltip()
    end)
    return
  end

  if #cands == 1 then
    -- Single match: jump without showing labels.
    jump_to(cands[1])
    avy_cancel()
    return
  end

  assign_labels(cands)
  state.candidates  = cands
  label_exact, label_prefix = build_label_map(cands)
  state.phase       = "select"
  state.label_input = ""
  update_status()
end

-- ---------------------------------------------------------------------------
-- Start avy session
-- ---------------------------------------------------------------------------

-- mode:      "char" | "word" | "line"
-- query_len: number of chars to collect before searching (0 for word/line)
local function avy_start(mode, query_len, dv)
  avy_reset()
  state.active    = true
  state.mode      = mode
  state.view      = dv
  state.query_len = query_len

  if query_len == 0 then
    -- word / line modes need no input; go straight to select.
    state.phase = "input"  -- find_and_enter_select checks mode, not query
    find_and_enter_select()
  else
    state.phase = "input"
    update_status()
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

  -- Always let modifier-only presses update keymap.modkeys.
  if modkey_map[k] then
    return original_on_key_pressed(k, ...)
  end

  local stroke = current_stroke(k)

  -- Cancel on escape or the avy:cancel binding.
  if k == "escape" or stroke_matches(stroke, "avy:cancel") then
    avy_cancel()
    return true
  end

  -- Plain printable char: no binding, no modifier → return false so the engine
  -- fires the subsequent textinput event, which core.on_event captures.
  local has_binding  = keymap.map[stroke] ~= nil
  local has_modifier = keymap.modkeys["ctrl"] or keymap.modkeys["alt"]
    or keymap.modkeys["super"] or keymap.modkeys["altgr"]

  if not has_binding and not has_modifier then
    return false  -- textinput fires → core.on_event handles it
  end

  -- Key with a binding or modifier while avy is active: cancel and pass through.
  avy_cancel()
  return original_on_key_pressed(k, ...)
end

-- ---------------------------------------------------------------------------
-- core.on_event wrapper — captures textinput for query and label input
-- ---------------------------------------------------------------------------

local original_on_event = core.on_event

core.on_event = function(type, ...)
  if state.active and type == "textinput" then
    local char = (...)

    if state.phase == "input" then
      -- Accumulate query characters.
      state.query = state.query .. char
      core.redraw = true
      if #state.query >= state.query_len then
        find_and_enter_select()
      else
        update_status()
      end

    elseif state.phase == "select" then
      local next_input = state.label_input .. char

      -- Check for an exact label match → jump.
      local matched = label_exact[next_input]
      if matched then
        jump_to(matched)
        avy_cancel()
        return true
      end

      -- Check if next_input is a valid prefix for any 2-char label.
      if label_prefix[next_input] then
        state.label_input = next_input
        update_status()
        core.redraw = true
        return true
      end

      -- Single-char labels only: if char is in exact map and we had no prefix.
      -- (Already handled above by exact check on next_input.)

      -- No match and no valid prefix → cancel.
      core.status_view:show_tooltip("avy: no match for '" .. next_input .. "'")
      core.redraw = true
      avy_reset()
      core.add_thread(function()
        coroutine.yield(1.0)
        core.status_view:remove_tooltip()
      end)
    end

    return true
  end
  return original_on_event(type, ...)
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

command.add("core.docview!", {
  ["avy:goto-char"]   = function(dv) avy_start("char", 1, dv) end,
  ["avy:goto-char-2"] = function(dv) avy_start("char", 2, dv) end,
  ["avy:goto-word"]   = function(dv) avy_start("word", 0, dv) end,
  ["avy:goto-line"]   = function(dv) avy_start("line", 0, dv) end,
})

command.add(function() return state.active end, {
  ["avy:cancel"] = avy_cancel,
})

-- Keybindings are centralized in configs/keymap/init.lua.

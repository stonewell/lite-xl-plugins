local core     = require "core"
local common   = require "core.common"
local style    = require "core.style"
local command  = require "core.command"
local ListView = require "plugins.shared.listview"

local KillRingView = ListView:extend()

function KillRingView:__tostring() return "KillRingView" end

function KillRingView:get_name()
  return "Kill Ring"
end

-- ring_ref: the module-level ring table from init.lua (passed by reference).
-- target_view: the DocView that was active when killring:open was invoked.
function KillRingView:new(target_view, ring_ref)
  KillRingView.super.new(self)
  self.target_view   = target_view
  self.ring          = ring_ref
  self._last_ring_n  = 0
  self:populate()
end

-- ---------------------------------------------------------------------------
-- Build result list from the ring
-- ---------------------------------------------------------------------------

local function first_line(text)
  return text:match("^([^\n]*)")
end

local function count_lines(text)
  local n = 0
  for _ in text:gmatch("\n") do n = n + 1 end
  return n
end

function KillRingView:populate()
  self.results = {}
  for _, entry in ipairs(self.ring) do
    local extra = count_lines(entry)
    table.insert(self.results, {
      text      = entry,
      preview   = first_line(entry),
      multiline = extra > 0,
      extra_lines = extra,
    })
  end
  self._last_ring_n = #self.ring
  self:update_filter(true)
end

-- ---------------------------------------------------------------------------
-- Abstract method implementations
-- ---------------------------------------------------------------------------

function KillRingView:get_item_text(item)
  return item.text
end

function KillRingView:get_status_text()
  return string.format("Kill Ring \xe2\x80\x94 %d / %d entries",
    #self.filtered_results, #self.results)
end

function KillRingView:draw_item(i, item, x, y, w, h)
  local is_sel     = (i == self.selected_idx)
  local idx_color  = style.dim
  local text_color = is_sel and style.accent or style.text
  local meta_color = style.dim

  x = x + style.padding.x

  -- Index gutter.
  local idx_str = string.format("%3d  ", i)
  x = common.draw_text(style.code_font, idx_color, idx_str, "left", x, y, w, h)

  -- First-line preview.
  x = common.draw_text(style.code_font, text_color, item.preview, "left", x, y, w, h)

  -- Multi-line indicator.
  if item.multiline then
    local tag = string.format("  [+%d lines]", item.extra_lines)
    x = common.draw_text(style.font, meta_color, tag, "left", x, y, w, h)
  end

  self.max_h_scroll = math.max(self.max_h_scroll, x)
end

-- ---------------------------------------------------------------------------
-- Paste selected entry into the target DocView
-- ---------------------------------------------------------------------------

function KillRingView:open_selected()
  local item = self.filtered_results[self.selected_idx]
  if not item then return end
  local tv = self.target_view
  if not (tv and tv.doc) then return end

  -- Update internal clipboard so doc:paste uses our chosen text.
  -- Deduplication in push_ring prevents double entries.
  core.cursor_clipboard             = { ["full"] = item.text, [1] = item.text }
  core.cursor_clipboard_whole_line  = { [1] = false }
  system.set_clipboard(item.text)

  -- Switch focus back to the target and paste.
  core.set_active_view(tv)
  command.perform("doc:paste")
  return true
end

-- ---------------------------------------------------------------------------
-- Update — re-populate when the ring grows while the view is open
-- ---------------------------------------------------------------------------

function KillRingView:update()
  KillRingView.super.update(self)
  if #self.ring ~= self._last_ring_n then
    self:populate()
  end
end

return KillRingView

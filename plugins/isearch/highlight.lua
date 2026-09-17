local config  = require "core.config"
local common  = require "core.common"
local DocView = require "core.docview"

config.plugins.isearch = common.merge({
  -- Default highlight color for non-current matches (translucent yellow).
  -- RGBA values 0-255.
  match_color    = { 255, 200, 50, 80 },
  case_sensitive = false,
}, config.plugins.isearch)

-- Shared state table.  init.lua modifies the fields at runtime; this module
-- only reads them during drawing.
local state = {
  active         = false,
  query          = "",
  direction      = "forward",
  view           = nil,   -- DocView where the search is active
  origin         = nil,   -- {l1, c1, l2, c2} cursor position to restore on cancel
  match          = nil,   -- {l1, c1, l2, c2} current match, or nil
  case_sensitive = false, -- per-session; seeded from config on each isearch_start
}

-- Hook into draw_line_text so that highlight rects are painted BEFORE text,
-- making text readable on top of the solid-color rectangles.
local old_draw_line_text = DocView.draw_line_text

function DocView:draw_line_text(line, x, y)
  if state.active and self == state.view and state.query ~= "" then
    local lh   = self:get_line_height()
    local text = self.doc.lines[line]
    local cs   = state.case_sensitive
    local q    = cs and state.query or state.query:lower()
    local src  = cs and text       or text:lower()
    local col  = 1
    while col <= #text do
      local s, e = src:find(q, col, true)
      if not s then break end
      -- The current match is already shown by the normal doc selection
      -- highlight; skip it here to avoid double-drawing.
      local is_current = state.match
        and state.match[1] == line
        and state.match[2] == s
        and state.match[4] == e + 1
      if not is_current then
        local x1 = x + self:get_col_x_offset(line, s)
        local x2 = x + self:get_col_x_offset(line, e + 1)
        renderer.draw_rect(x1, y, x2 - x1, lh, config.plugins.isearch.match_color)
      end
      col = s + 1
    end
  end
  return old_draw_line_text(self, line, x, y)
end

return state

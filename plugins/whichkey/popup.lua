local core   = require "core"
local common = require "core.common"
local config = require "core.config"
local style  = require "core.style"

-- Greedily wrap `text` into lines that fit within `max_w` pixels for `font`,
-- breaking on spaces, "/" and "," (which-key style labels like
-- "buffer/window/frame" or "occur, multi-buffer" have no spaces to break on
-- otherwise). Falls back to a hard character split for a single token wider
-- than `max_w` on its own. Caps output at `max_lines`, appending "…" to the
-- last line if text remains.
local function wrap_text(font, text, max_w, max_lines)
  if font:get_width(text) <= max_w then
    return { text }
  end

  local chunks = {}
  for chunk in text:gmatch("[^ /,]*[ /,]?") do
    if chunk ~= "" then table.insert(chunks, chunk) end
  end

  local lines, line = {}, ""
  for _, chunk in ipairs(chunks) do
    local candidate = line .. chunk
    if line ~= "" and font:get_width(candidate) > max_w then
      table.insert(lines, line)
      line = chunk
    else
      line = candidate
    end
  end
  if line ~= "" then table.insert(lines, line) end

  -- Hard-split any line that's still too wide (a single unbreakable token).
  local wrapped = {}
  for _, l in ipairs(lines) do
    if font:get_width(l) <= max_w then
      table.insert(wrapped, l)
    else
      local cur = ""
      for i = 1, #l do
        local ch = l:sub(i, i)
        local candidate = cur .. ch
        if cur ~= "" and font:get_width(candidate) > max_w then
          table.insert(wrapped, cur)
          cur = ch
        else
          cur = candidate
        end
      end
      if cur ~= "" then table.insert(wrapped, cur) end
    end
  end

  if #wrapped > max_lines then
    local kept = {}
    for i = 1, max_lines do kept[i] = wrapped[i] end
    local last = kept[max_lines] .. "…"
    while font:get_width(last) > max_w and #kept[max_lines] > 0 do
      kept[max_lines] = kept[max_lines]:sub(1, -2)
      last = kept[max_lines] .. "…"
    end
    kept[max_lines] = last
    wrapped = kept
  end

  return wrapped
end

-- Draw the which-key popup panel above the status bar.
-- root_view: the RootView instance (provides size).
-- state: the shared state table from init.lua.
local function draw(root_view, state)
  local sw        = root_view.size.x
  local sv_h      = core.status_view and core.status_view.size.y or 0
  local lh        = style.font:get_height() + style.padding.y
  -- Scaled here (rather than once at plugin-load time) so it reflects
  -- whatever SCALE currently is, not just its value at startup.
  local cw        = config.plugins.whichkey.col_width * SCALE
  local ncol      = math.max(1, math.floor(sw / cw))
  local nrow      = math.max(1, math.ceil(#state.entries / ncol))
  local max_lines = config.plugins.whichkey.max_desc_lines

  -- Shared key gutter: every column's description starts at the same x,
  -- instead of drifting per-entry based on that entry's own key width.
  local key_gutter = 0
  for _, entry in ipairs(state.entries) do
    key_gutter = math.max(key_gutter, style.font:get_width(entry.key))
  end
  key_gutter = key_gutter + style.padding.x
  local desc_w = math.max(1, cw - key_gutter - style.padding.x)

  -- Wrap descriptions and compute each row's height up front, since a row
  -- with a wrapped (multi-line) entry needs to be taller than a plain row.
  local row_lines = {}
  for i, entry in ipairs(state.entries) do
    entry.lines = wrap_text(style.font, entry.display, desc_w, max_lines)
    local row = math.floor((i - 1) / ncol) + 1
    row_lines[row] = math.max(row_lines[row] or 1, #entry.lines)
  end

  local row_y, y_acc = {}, 0
  for row = 1, nrow do
    row_y[row] = y_acc
    y_acc = y_acc + row_lines[row] * lh
  end

  -- Header row + entry rows.
  local ph = lh + y_acc + style.padding.y
  local py = root_view.size.y - ph - sv_h

  -- Background and top border.
  renderer.draw_rect(0, py, sw, ph, style.background2)
  renderer.draw_rect(0, py, sw, style.divider_size, style.divider)

  -- Header: "which-key: <prefix> -"
  local header = "which-key: " .. (state.prefix or "") .. " -"
  renderer.draw_text(style.font, header,
    style.padding.x, py + style.padding.y / 2, style.dim)

  -- Entry rows (fill columns left-to-right, then wrap to next row).
  local entry_y0 = py + lh + style.padding.y / 2

  for i, entry in ipairs(state.entries) do
    local col   = (i - 1) % ncol
    local row   = math.floor((i - 1) / ncol) + 1
    local x     = col * cw + style.padding.x
    local y     = entry_y0 + row_y[row]
    local row_h = row_lines[row] * lh

    -- Defensive backstop: even if wrapping math is off by a hair, this
    -- keeps one column's text from bleeding into its neighbor.
    core.push_clip_rect(x, y, cw - style.padding.x, row_h)

    -- Key in accent color (left-aligned within the shared key gutter).
    common.draw_text(style.font, style.accent, entry.key, "left", x, y, key_gutter, lh)

    -- Command / group description, one call per wrapped line.
    local desc_color = entry.is_prefix and style.accent or style.text
    for j, line in ipairs(entry.lines) do
      common.draw_text(style.font, desc_color, line, "left",
        x + key_gutter, y + (j - 1) * lh, desc_w, lh)
    end

    core.pop_clip_rect()
  end
end

return { draw = draw }

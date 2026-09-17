local core     = require "core"
local common   = require "core.common"
local style    = require "core.style"
local DocView  = require "core.docview"
local ListView = require "plugins.shared.listview"

local BufferExView = ListView:extend()

function BufferExView:__tostring() return "BufferExView" end

function BufferExView:get_name()
  return "Buffers & Recent Files"
end

-- ---------------------------------------------------------------------------
-- Build the open-buffer list
-- ---------------------------------------------------------------------------

local function get_open_buffers(current_doc)
  local seen    = {}
  local buffers = {}
  local views   = core.root_view.root_node:get_children()
  for _, view in ipairs(views) do
    if view:is(DocView) and view.doc then
      local filename = view.doc.filename
      if filename and not seen[filename] then
        seen[filename] = true
        table.insert(buffers, {
          kind     = "buffer",
          display  = common.basename(filename),
          filename = filename,
          view     = view,
          doc      = view.doc,
          current  = (view.doc == current_doc),
        })
      elseif not filename then
        local name = view:get_name()
        if not seen[name] then
          seen[name] = true
          table.insert(buffers, {
            kind     = "buffer",
            display  = name,
            filename = nil,
            view     = view,
            doc      = view.doc,
            current  = (view.doc == current_doc),
          })
        end
      end
    end
  end
  return buffers, seen
end

-- ---------------------------------------------------------------------------
-- Constructor / populate
-- ---------------------------------------------------------------------------

function BufferExView:new(current_doc)
  BufferExView.super.new(self)
  self._current_doc        = current_doc or nil
  self._last_visited_count = 0
  self._last_buffer_count  = 0
  self:populate()
end

function BufferExView:populate(current_doc)
  if current_doc ~= nil then
    self._current_doc = current_doc
  end

  local buffers, seen = get_open_buffers(self._current_doc)

  local recents = {}
  for _, filename in ipairs(core.visited_files or {}) do
    if not seen[filename] then
      seen[filename] = true
      table.insert(recents, {
        kind     = "recent",
        display  = common.basename(filename),
        filename = filename,
      })
    end
  end

  self.results = {}
  for _, item in ipairs(buffers) do table.insert(self.results, item) end
  for _, item in ipairs(recents) do table.insert(self.results, item) end

  self._last_buffer_count  = #buffers
  self._last_visited_count = #(core.visited_files or {})

  self:update_filter(true)
end

-- ---------------------------------------------------------------------------
-- Abstract method implementations
-- ---------------------------------------------------------------------------

function BufferExView:get_item_text(item)
  return item.display .. " " .. (item.filename or "")
end

function BufferExView:get_status_text()
  -- Count only selectable items for the display fraction.
  local sel = 0
  for _, item in ipairs(self.filtered_results) do
    if item.selectable ~= false then sel = sel + 1 end
  end
  local total = 0
  for _, item in ipairs(self.results) do
    if item.selectable ~= false then total = total + 1 end
  end
  return string.format("Buffers & Recent Files \xe2\x80\x94 %d / %d", sel, total)
end

-- ---------------------------------------------------------------------------
-- Grouped update_filter (overrides ListView base)
-- ---------------------------------------------------------------------------

function BufferExView:update_filter(reset_selection)
  local ft = self.filter_doc:get_text(1, 1, 1, math.huge)

  local function matches(item)
    if ft == "" then return true end
    return common.fuzzy_match(self:get_item_text(item), ft)
  end

  local bufs, recs = {}, {}
  for _, item in ipairs(self.results) do
    if item.kind == "buffer" and matches(item) then
      table.insert(bufs, item)
    elseif item.kind == "recent" and matches(item) then
      table.insert(recs, item)
    end
  end

  self.filtered_results = {}
  if #bufs > 0 then
    table.insert(self.filtered_results, {
      kind = "header", display = "Open Buffers", selectable = false
    })
    for _, item in ipairs(bufs) do
      table.insert(self.filtered_results, item)
    end
  end
  if #recs > 0 then
    table.insert(self.filtered_results, {
      kind = "header", display = "Recent Files", selectable = false
    })
    for _, item in ipairs(recs) do
      table.insert(self.filtered_results, item)
    end
  end

  -- Ensure selected_idx lands on a selectable row.
  local function first_selectable()
    for i, item in ipairs(self.filtered_results) do
      if item.selectable ~= false then return i end
    end
    return 0
  end

  if reset_selection or self.selected_idx == 0 then
    self.selected_idx = first_selectable()
    if reset_selection then self.scroll.to.y = 0 end
  else
    self.selected_idx = math.min(self.selected_idx, #self.filtered_results)
    local cur = self.filtered_results[self.selected_idx]
    if cur and cur.selectable == false then
      self.selected_idx = first_selectable()
    end
  end
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

function BufferExView:draw_item(i, item, x, y, w, h)
  -- Group header row.
  if item.kind == "header" then
    local lx = x + style.padding.x
    common.draw_text(style.font, style.dim, item.display, "left", lx, y, w, h)
    local ly = y + h - style.divider_size
    renderer.draw_rect(self.position.x, ly, self.size.x, style.divider_size, style.divider)
    return
  end

  local is_sel   = (i == self.selected_idx)
  local is_dirty = item.doc and item.doc:is_dirty()

  x = x + style.padding.x

  -- Kind tag.
  local tag = (item.kind == "buffer")
    and (item.current and "[+] " or "[B] ")
    or  "[R] "
  x = common.draw_text(style.font, style.dim, tag, "left", x, y, w, h)

  -- Display name with optional dirty marker.
  local name_color = is_sel and style.accent or style.text
  local name       = item.display .. (is_dirty and " *" or "")
  x = common.draw_text(style.font, name_color, name, "left", x, y, w, h)

  -- Relative / shortened path (dim).
  if item.filename then
    local project = core.root_project()
    local rel = (project and project.path ~= "")
      and project:normalize_path(item.filename)
      or item.filename
    x = common.draw_text(style.font, style.dim, "  " .. rel, "left", x, y, w, h)
  end

  self.max_h_scroll = math.max(self.max_h_scroll, x)
end

-- ---------------------------------------------------------------------------
-- Open selected — guard against header rows
-- ---------------------------------------------------------------------------

function BufferExView:open_selected()
  local item = self.filtered_results[self.selected_idx]
  if not item or item.selectable == false then return end
  core.try(function()
    if item.kind == "buffer" and item.view then
      core.root_view:open_doc(item.view.doc)
    elseif item.filename then
      core.root_view:open_doc(core.open_doc(item.filename))
    end
  end)
  return true
end

-- ---------------------------------------------------------------------------
-- Update — re-populate when open buffers or visited files change
-- ---------------------------------------------------------------------------

function BufferExView:update()
  BufferExView.super.update(self)

  local current_visited = #(core.visited_files or {})
  local _, seen_now = get_open_buffers(self._current_doc)
  local current_buffers = 0
  for _ in pairs(seen_now) do current_buffers = current_buffers + 1 end

  if current_visited ~= self._last_visited_count
  or current_buffers ~= self._last_buffer_count then
    self:populate()
  end
end

return BufferExView

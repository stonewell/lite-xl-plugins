local core     = require "core"
local common   = require "core.common"
local config   = require "core.config"
local style    = require "core.style"
local process  = require "core.process"
local ListView = require "plugins.shared.listview"
local H        = require "plugins.shared.search_helpers"

config.plugins.rgsearch = common.merge({
  executable  = "rg",
  extra_flags = { "--vimgrep", "--smart-case", "--follow" },
}, config.plugins.rgsearch)

local RgView = ListView:extend()

function RgView:__tostring() return "RgView" end

function RgView:new(query, root)
  RgView.super.new(self)
  self.query   = ""
  self.root    = root
  self.searching = false
  self:begin_search(query)
end

function RgView:get_name()
  return "Rg: " .. (self.query or "")
end

-- ---------------------------------------------------------------------------
-- Abstract method implementations
-- ---------------------------------------------------------------------------

function RgView:get_item_text(item)
  return common.basename(item.file) .. " " .. item.text
end

function RgView:get_status_text()
  local ft = self.filter_doc:get_text(1, 1, 1, math.huge)
  if self.searching then
    return string.format("Searching (%d matches) for %q...", #self.results, self.query)
  elseif ft ~= "" then
    return string.format("%d / %d matches for %q", #self.filtered_results, #self.results, self.query)
  else
    return string.format("Found %d matches for %q", #self.results, self.query)
  end
end

function RgView:draw_item(i, item, x, y, w, h)
  local match_color = (i == self.selected_idx) and style.accent or style.text
  x = x + style.padding.x
  local project = core.root_project()
  local rel = (project and project.path ~= "")
    and project:normalize_path(item.file)
    or common.basename(item.file)
  local loc = string.format(":%d:%d: ", item.line, item.col)
  x = common.draw_text(style.font,      style.accent,   rel,       "left", x, y, w, h)
  x = common.draw_text(style.font,      style.text,     loc,       "left", x, y, w, h)
  x = common.draw_text(style.code_font, match_color,    item.text, "left", x, y, w, h)
  self.max_h_scroll = math.max(self.max_h_scroll, x)
end

function RgView:open_selected()
  local res = self.filtered_results[self.selected_idx]
  if not res then return end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(res.file))
    core.root_view.root_node:update_layout()
    dv.doc:set_selection(res.line, res.col)
    dv:scroll_to_line(res.line, false, true)
  end)
  return true
end

-- Keep old name as alias (used from rgsearch/init.lua).
RgView.open_selected_result = RgView.open_selected

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

function RgView:begin_search(query)
  self.results          = {}
  self.filtered_results = {}
  self.filter_doc:remove(1, 1, math.huge, math.huge)
  self.filter_change_id = self.filter_doc:get_change_id()
  self.query            = query
  self.searching        = true
  self.selected_idx     = 0
  self.max_h_scroll     = 0
  self.scroll.to.y      = 0

  local root = self.root
  local cfg  = config.plugins.rgsearch
  local cmd  = H.build_cmd(cfg.executable, cfg.extra_flags, "--", query, root)

  core.log("rg-search: %s", table.concat(cmd, " "))

  core.add_thread(function()
    local ok, proc = pcall(process.start, cmd)
    if not ok then
      core.error("rg-search: failed to start rg: %s", proc)
      self.searching = false
      return
    end

    while true do
      local line = proc.stdout:read("line")
      if not line then break end
      -- Lazy pattern: handles Windows drive-letter colons (e.g. C:\foo:10:5:text)
      local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)")
      if file then
        table.insert(self.results, {
          file = file,
          line = tonumber(lnum),
          col  = tonumber(col),
          text = text,
        })
        self:update_filter()
        core.redraw = true
      end
    end

    self.searching = false
    core.redraw = true
  end)
end

function RgView:refresh()
  local ft = self.filter_doc:get_text(1, 1, 1, math.huge)
  self:begin_search(ft ~= "" and ft or self.query)
end

-- ---------------------------------------------------------------------------
-- Update — keep redrawing while rg is running
-- ---------------------------------------------------------------------------

function RgView:update()
  RgView.super.update(self)
  if self.searching then
    core.redraw = true
  end
end

return RgView

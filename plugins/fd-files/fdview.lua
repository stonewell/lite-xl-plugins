local core     = require "core"
local common   = require "core.common"
local config   = require "core.config"
local style    = require "core.style"
local process  = require "core.process"
local ListView = require "plugins.shared.listview"
local H        = require "plugins.shared.search_helpers"

config.plugins.fd_files = common.merge({
  executable  = "fd",
  extra_flags = { "--type", "f", "--follow" },
  max_results = 500,
}, config.plugins.fd_files)

local FdView = ListView:extend()

function FdView:__tostring() return "FdView" end

function FdView:new(root)
  FdView.super.new(self)
  self.root      = root
  self.searching = false
  self:begin_search()
end

function FdView:get_name()
  return "fd: " .. (self.root or ".")
end

-- ---------------------------------------------------------------------------
-- Abstract method implementations
-- ---------------------------------------------------------------------------

function FdView:get_item_text(item)
  return item.path
end

function FdView:get_status_text()
  local ft = self.filter_doc:get_text(1, 1, 1, math.huge)
  if self.searching then
    return string.format("Searching (%d files) in %s...", #self.results, self.root)
  elseif ft ~= "" then
    return string.format("%d / %d files in %s", #self.filtered_results, #self.results, self.root)
  else
    return string.format("%d files in %s", #self.results, self.root)
  end
end

function FdView:draw_item(i, item, x, y, w, h)
  local col = (i == self.selected_idx) and style.accent or style.text
  x = x + style.padding.x
  local project = core.root_project()
  local rel = (project and project.path ~= "")
    and project:normalize_path(item.path)
    or common.basename(item.path)
  x = common.draw_text(style.font, col, rel, "left", x, y, w, h)
  self.max_h_scroll = math.max(self.max_h_scroll, x)
end

function FdView:open_selected()
  local item = self.filtered_results[self.selected_idx]
  if not item then return end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(item.path))
    core.root_view.root_node:update_layout()
    dv:scroll_to_line(1, false, true)
  end)
  return true
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

function FdView:begin_search()
  self.results          = {}
  self.filtered_results = {}
  self.filter_doc:remove(1, 1, math.huge, math.huge)
  self.filter_change_id = self.filter_doc:get_change_id()
  self.searching        = true
  self.selected_idx     = 0
  self.max_h_scroll     = 0
  self.scroll.to.y      = 0

  local root = self.root
  local cfg  = config.plugins.fd_files
  local cmd  = H.build_cmd(cfg.executable, cfg.extra_flags, "--max-results", tostring(cfg.max_results), ".", root)

  core.log("fd-files: %s", table.concat(cmd, " "))

  core.add_thread(function()
    local ok, proc = pcall(process.start, cmd)
    if not ok then
      core.error("fd-files: failed to start fd: %s", proc)
      self.searching = false
      return
    end

    local count = 0
    while count < cfg.max_results do
      local line = proc.stdout:read("line")
      if not line then break end
      line = line:gsub("[\r\n]+$", "")
      if line ~= "" then
        count = count + 1
        table.insert(self.results, { path = line })
        self:update_filter()
        core.redraw = true
      end
    end

    self.searching = false
    core.redraw = true
  end)
end

function FdView:refresh()
  local root = self.root
  -- Re-detect root in case the active doc changed.
  self.root = H.get_search_root()
  if self.root ~= root then
    core.log("fd-files: refresh root changed to %s", self.root)
  end
  self:begin_search()
end

-- ---------------------------------------------------------------------------
-- Update — keep redrawing while fd is running
-- ---------------------------------------------------------------------------

function FdView:update()
  FdView.super.update(self)
  if self.searching then
    core.redraw = true
  end
end

return FdView

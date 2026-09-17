-- mod-version:3
local config = require "core.config"
local Cache = require "plugins.indentguideex.cache"

local Scope = {}

local ROOT_NODE_TYPES = {
  chunk = true,
  source_file = true,
  program = true,
  translation_unit = true,
  module = true,
  document = true,
}

---Resolve active block scope using Tree-sitter AST
---@param doc core.doc
---@param line integer
---@param col integer
---@param indent_size integer
---@return integer? start_line, integer? end_line, integer? active_lvl
local function get_treesit_scope(doc, line, col, indent_size)
  if not (doc.treesit and doc.ts and doc.ts.tree) then
    return nil
  end

  local ts_lib = require "libraries.tree_sitter"
  local row = math.max(0, line - 1)
  local col_0 = math.max(0, col - 1)
  local pt = ts_lib.Point.new(row, col_0)

  local root = doc.ts.tree:root_node()
  if not root then return nil end

  local ok, node = pcall(function()
    return root:named_descendant_for_point_range(pt, pt)
  end)
  if not ok or not node then return nil end

  local curr = node
  local block_node = nil
  while curr do
    local p = curr:parent()
    if not p or ROOT_NODE_TYPES[curr:type()] then break end
    local s_row = curr:start_point():row() + 1
    local e_row = curr:end_point():row() + 1
    if s_row < e_row then
      block_node = curr
      break
    end
    curr = p
  end

  if not block_node then return nil end

  local s_line = block_node:start_point():row() + 1
  local e_line = block_node:end_point():row() + 1

  -- Calculate indent level for this block
  local header_indent = Cache.get_raw_indent(doc, s_line)
  if header_indent < 0 then
    header_indent = Cache.get_guide_spaces(doc, s_line)
  end
  local active_lvl = header_indent + indent_size

  return s_line, e_line, active_lvl
end

---Compute active scope indents table for all visible lines in docview.
---Returns a map [line] -> active_lvl for lines within the active scope.
---@param docview core.docview
---@param minline integer
---@param maxline integer
---@return table<integer, integer>
function Scope.get_active_indents(docview, minline, maxline)
  local doc = docview.doc
  if doc.large_file then return {} end

  local line1, col1 = doc:get_selection()
  local _, indent_size = doc:get_indent_info()
  indent_size = indent_size or config.indent_size or 2

  local active_indents = {}
  local max_margin = 200

  -- Only compute active scope if caret is within or near visible range
  if line1 < minline - max_margin or line1 > maxline + max_margin then
    return active_indents
  end

  -- 1. Try Tree-sitter scope detection
  local s_line, e_line, ts_lvl = get_treesit_scope(doc, line1, col1, indent_size)
  if s_line and e_line and ts_lvl then
    local from_line = math.max(minline, s_line)
    local to_line = math.min(maxline, e_line)
    for l = from_line, to_line do
      active_indents[l] = ts_lvl
    end
    return active_indents
  end

  -- 2. Fallback: Indentation-based block detection
  local lvl = Cache.get_guide_spaces(doc, line1)
  if lvl <= 0 then return active_indents end

  local top, bottom
  local next_indent = Cache.get_guide_spaces(doc, line1 + 1)
  local prev_indent = Cache.get_guide_spaces(doc, line1 - 1)

  if next_indent > lvl and next_indent <= lvl + indent_size then
    top = true
    lvl = next_indent
  elseif prev_indent > lvl and prev_indent <= lvl + indent_size then
    bottom = true
    lvl = prev_indent
  end

  active_indents[line1] = lvl

  -- Walk upwards
  local i = line1 - 1
  local min_limit = math.max(1, minline - 10)
  if i > 0 and not top then
    while i >= min_limit do
      local ind = Cache.get_guide_spaces(doc, i)
      if ind <= lvl - indent_size then break end
      active_indents[i] = lvl
      i = i - 1
    end
  end

  -- Walk downwards
  i = line1 + 1
  local max_limit = math.min(#doc.lines, maxline + 10)
  if i <= #doc.lines and not bottom then
    while i <= max_limit do
      local ind = Cache.get_guide_spaces(doc, i)
      if ind <= lvl - indent_size then break end
      active_indents[i] = lvl
      i = i + 1
    end
  end

  return active_indents
end

return Scope

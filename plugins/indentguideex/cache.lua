-- mod-version:3
local config = require "core.config"

local Cache = {}
local doc_caches = setmetatable({}, { __mode = "k" })

local function get_doc_cache(doc)
  local c = doc_caches[doc]
  local change_id = doc:get_change_id()
  local _, indent_size = doc:get_indent_info()
  if not c or c.change_id ~= change_id or c.indent_size ~= indent_size then
    c = {
      change_id = change_id,
      indent_size = indent_size or config.indent_size or 2,
      raw_indents = {},
      guide_spaces = {},
    }
    doc_caches[doc] = c
  end
  return c
end

---Calculate raw indentation in spaces/columns for a line.
---Returns -1 if the line is blank/empty/whitespace-only.
---Zero table allocation using direct byte scanning.
---@param doc core.doc
---@param line integer
---@return integer
function Cache.get_raw_indent(doc, line)
  if line < 1 or line > #doc.lines then return -1 end
  local c = get_doc_cache(doc)
  local cached = c.raw_indents[line]
  if cached ~= nil then return cached end

  local text = doc.lines[line]
  if not text or #text <= 1 then
    c.raw_indents[line] = -1
    return -1
  end

  local indent_size = c.indent_size
  local n = 0
  local has_non_space = false
  local len = #text

  for i = 1, len do
    local b = text:byte(i)
    if b == 32 then -- ' '
      n = n + 1
    elseif b == 9 then -- '\t'
      n = n + (indent_size - (n % indent_size))
    elseif b == 10 or b == 13 then -- '\n' or '\r'
      break
    else
      has_non_space = true
      break
    end
  end

  local result = has_non_space and n or -1
  c.raw_indents[line] = result
  return result
end

---Find nearest non-blank line indent searching in direction dir (-1 or 1).
---Bounded by max_search to prevent deep scans.
---@param doc core.doc
---@param start_line integer
---@param dir integer
---@param max_search integer?
---@return integer
local function find_nearest_indent(doc, start_line, dir, max_search)
  max_search = max_search or 100
  local line = start_line + dir
  local count = 0
  local total_lines = #doc.lines
  while line >= 1 and line <= total_lines and count < max_search do
    local indent = Cache.get_raw_indent(doc, line)
    if indent >= 0 then
      return indent
    end
    line = line + dir
    count = count + 1
  end
  return -1
end

---Calculate guide spaces for a line.
---If non-blank, returns raw indentation.
---If blank, returns max(nearest above, nearest below) within bounded search.
---@param doc core.doc
---@param line integer
---@return integer
function Cache.get_guide_spaces(doc, line)
  if line < 1 or line > #doc.lines then return -1 end
  local c = get_doc_cache(doc)
  local cached = c.guide_spaces[line]
  if cached ~= nil then return cached end

  local raw = Cache.get_raw_indent(doc, line)
  if raw >= 0 then
    c.guide_spaces[line] = raw
    return raw
  end

  local above = find_nearest_indent(doc, line, -1, 100)
  local below = find_nearest_indent(doc, line, 1, 100)
  local res = math.max(above, below)
  c.guide_spaces[line] = res
  return res
end

---Invalidate cache for a doc or all docs
---@param doc core.doc?
function Cache.clear(doc)
  if doc then
    doc_caches[doc] = nil
  else
    for k in pairs(doc_caches) do
      doc_caches[k] = nil
    end
  end
end

return Cache

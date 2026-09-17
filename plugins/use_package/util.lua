local M = {}

function M.exec(cmd, opts)
  local proc = process.start(cmd, opts or {})
  if proc then
    while proc:running() do
      coroutine.yield(0.1)
    end
    return (proc:read_stdout() or '<no stdout>') .. (proc:read_stderr() or '<no stderr>'),
           proc:returncode()
  end
  return nil, -1
end

-- Run a shell command string inside a working directory, cross-platform.
function M.runInDir(cmd, dir)
  local shell
  if PLATFORM == 'Windows' then
    shell = {'cmd', '/c', cmd}
  else
    shell = {'sh', '-c', cmd}
  end
  return M.exec(shell, {cwd = dir})
end

function M.gitCmd(args, dir)
  return M.exec({'git', '-C', dir, table.unpack(args)})
end

function M.isURL(url)
  return url:match('^%w+://')
end

-- Returns "Author/RepoName" if url matches that pattern, else nil.
function M.slugify(url)
  return url:match('^[^/]+/[^/]+$')
end

-- Derive a short plugin name from a URL or slug.
-- Strips ".lxl" suffix and "lite-xl-" prefix.
function M.plugName(url)
  local name = string.lower(url:match('[^/]+$'))
  return name:gsub('%.lxl$', ''):gsub('^lite%-xl%-', '')
end

-- Normalize path separators to the OS separator and collapse duplicate separators.
-- On Windows: converts all '/' to '\', then collapses consecutive '\' into one
-- (UNC paths starting with '\\' are preserved).
function M.normPath(path)
  if PLATFORM == 'Windows' then
    path = path:gsub('/', '\\')
    if path:sub(1, 2) == '\\\\' then
      return '\\\\' .. path:sub(3):gsub('\\+', '\\')
    end
    return (path:gsub('\\+', '\\'))
  end
  return path
end

-- Create all missing directory segments in path, like mkdir -p.
function M.mkdirp(path)
  path = M.normPath(path)
  local sep = PATHSEP == '\\' and '\\' or '/'
  local parts = {}
  for seg in path:gmatch('[^' .. sep .. ']+') do
    parts[#parts + 1] = seg
  end
  local cur = path:sub(1, 1) == sep and sep or ''
  for _, seg in ipairs(parts) do
    cur = cur == '' and seg or (cur .. sep .. seg)
    if not system.get_file_info(cur) then
      system.mkdir(cur)
    end
  end
end

-- Works for both files and directories, and resolves junction points on Windows.
function M.fileExists(path)
  return system.get_file_info(M.normPath(path)) ~= nil
end

-- Binary-safe single-file copy.
local function copyFile(src, dest)
  local fi, err = io.open(src, 'rb')
  if not fi then return false, err end
  local fo, err2 = io.open(dest, 'wb')
  if not fo then fi:close(); return false, err2 end
  local CHUNK = 65536
  repeat
    local buf = fi:read(CHUNK)
    if buf then fo:write(buf) end
  until not buf
  fi:close(); fo:close()
  return true
end

-- Recursively copy a file or directory using only lite-xl built-ins.
-- No external processes; works on all platforms.
function M.copy(src, dest)
  local info = system.get_file_info(src)
  if not info then return false, 'source not found: ' .. src end
  if info.type == 'dir' then
    M.mkdirp(dest)
    for _, item in ipairs(system.list_dir(src) or {}) do
      local ok, err = M.copy(src .. PATHSEP .. item, dest .. PATHSEP .. item)
      if not ok then return false, err end
    end
    return true
  end
  local parent = dest:match('^(.*)[/\\][^/\\]+$')
  if parent then
    M.mkdirp(parent)
  end
  return copyFile(src, dest)
end

-- Recursively remove a file or directory, like rm -rf.
function M.rmrf(path)
  path = M.normPath(path)
  local info = system.get_file_info(path)
  if not info then return end
  if info.type == 'dir' then
    for _, item in ipairs(system.list_dir(path) or {}) do
      M.rmrf(path .. PATHSEP .. item)
    end
  end
  os.remove(path)
end

-- True for paths the user intends as local filesystem references.
-- Handles Unix-style (~/, /, ./, ../) and Windows absolute paths (C:\, D:\).
function M.isLocalPath(path)
  local prefixes = { '~/', '/', '../', './' }
  for _, pref in ipairs(prefixes) do
    if path:find(pref, 1, true) == 1 then return true end
  end
  -- Windows: drive letter followed by backslash (C:\, D:\, etc.)
  if path:match('^%a:[/\\]') then return true end
  return false
end

function M.hexify(str)
  return (str:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

function M.dehexify(hex)
  return (hex:gsub('%x%x', function(d) return string.char(tonumber(d, 16)) end))
end

-- Strip the ":tag" suffix from a "url:tag" repo string, returning just the URL.
-- Pattern anchored to "protocol://" so the colon in "https:" is not treated as separator.
function M.repoURL(repo)
  return repo:match('^%w+://[^:]+')
end

-- Extract the tag from a "url:tag" repo string. Returns nil if no tag present.
function M.repoTag(repo)
  return repo:match('^%w+://.+:(.+)')
end

function M.repoDir(repo)
  return M.hexify(M.repoURL(repo))
end

function M.join(parts)
  local str = ''
  local sep_pat = string.format('%s$', '%' .. PATHSEP)
  for i, part in ipairs(parts) do
    local has_sep = part:match(sep_pat)
    str = str .. part .. (has_sep and '' or i == #parts and '' or PATHSEP)
  end
  return str:gsub(string.format('%s$', '%' .. PATHSEP), '')
end

return M

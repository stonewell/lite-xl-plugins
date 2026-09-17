local core        = require 'core'
local common      = require 'core.common'
local Promise     = require 'plugins.use_package.promise'
local util        = require 'plugins.use_package.util'
local manifestlib = require 'plugins.use_package.manifest'

local M = {}

-- ---------------------------------------------------------------------------
-- fromGit — clone a single-repo plugin from GitHub (or any git URL)
-- ---------------------------------------------------------------------------
function M.fromGit(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local url = util.isURL(spec.plugin) and spec.plugin
                or ('https://github.com/' .. spec.plugin)
    local dest = USERDIR .. '/plugins/' .. spec.name
    if util.fileExists(dest) then
      promise:resolve()
      return
    end
    local out, code = util.exec({'git', 'clone', url, dest})
    if code ~= 0 then
      promise:reject(out)
      return
    end
    promise:resolve()
  end)
  return promise
end

-- Update a git-cloned plugin via git pull.
function M.updateGit(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local dir = USERDIR .. '/plugins/' .. spec.name
    local out, code = util.gitCmd({'pull'}, dir)
    if code ~= 0 then
      promise:reject(out)
      return
    end
    promise:resolve(out:match('Already up to date') and true or false)
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- fromLocal — symlink a local filesystem path into the plugins dir
-- ---------------------------------------------------------------------------
function M.fromLocal(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local src      = util.normPath(common.home_expand(spec.plugin))
    local dest_dir = util.normPath(USERDIR .. (spec.library and '/libraries' or '/plugins'))
    local name     = spec.name or util.plugName(common.basename(spec.plugin))
    local dest     = util.normPath(util.join({dest_dir, name}))

    system.mkdir(dest_dir)

    if not util.fileExists(src) then
      promise:reject(string.format('[use-package] source does not exist: %s', src))
      return
    end

    if util.fileExists(dest) then
      promise:resolve()
      return
    end

    if PLATFORM == 'Windows' then
      core.log('[use-package] copy %s -> %s', src, dest)
      local ok, err = util.copy(src, dest)
      if not ok then
        promise:reject('[use-package] copy failed: ' .. (err or 'unknown'))
      else
        promise:resolve()
      end
      return
    end

    local out, code = util.exec({'ln', '-s', src, dest})
    if code ~= 0 then promise:reject(out) else promise:resolve() end
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- fromRepo — install a plugin from a multi-plugin repo manifest
-- ---------------------------------------------------------------------------
function M.fromRepo(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local search_hex = spec.repo and util.repoDir(spec.repo) or nil
    local addon, hex = manifestlib.searchAddon(spec.name, search_hex)

    if not addon then
      promise:reject(string.format(
        '[use-package] no addon "%s" found in any registered repo', spec.name))
      return
    end

    -- If the addon lives in its own sub-repo, fetch it first then re-search.
    if addon.remote then
      local remote_url = addon.remote
      local out, code = manifestlib.downloadRepo(remote_url)
      if code ~= 0 then
        promise:reject(out)
        return
      end
      -- re-search in the newly downloaded sub-repo
      local sub_hex = util.repoDir(remote_url)
      addon, hex = manifestlib.searchAddon(spec.name, sub_hex)
      if not addon then
        promise:reject(string.format(
          '[use-package] addon "%s" not found in sub-repo %s', spec.name, remote_url))
        return
      end
    end

    if addon.type and addon.type ~= 'plugin' and addon.type ~= 'library' then
      promise:reject(string.format(
        '[use-package] addon "%s" has unsupported type "%s"', spec.name, addon.type))
      return
    end

    local repo_dir  = manifestlib.repoLocalDir(util.dehexify(hex))
    local src_path  = addon.path and (repo_dir .. '/' .. addon.path) or repo_dir
    local file_name = addon.path and (addon.path:match('[^\\/]+$') or spec.name) or spec.name

    M.fromLocal({
      plugin  = src_path,
      name    = file_name,
      library = (addon.type == 'library'),
    }):forward(promise)
  end)
  return promise
end

-- Update a repo-installed plugin:
-- pull the cached repo clone, then re-run fromLocal to refresh the file.
function M.updateRepo(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local stored = require('plugins.use_package.store').getPlugin(spec.plugin)
    if not stored or not stored.repo_hex then
      promise:reject(string.format(
        '[use-package] no cached repo info for "%s"', spec.name))
      return
    end

    local repo_url = util.dehexify(stored.repo_hex)
    local out, code = manifestlib.updateRepo(repo_url)
    if code ~= 0 then
      promise:reject(out)
      return
    end

    -- Refresh the installed file by re-running fromLocal
    local addon = manifestlib.searchAddon(spec.name, stored.repo_hex)
    if not addon then
      promise:resolve(true)  -- already up to date, file unchanged
      return
    end

    local repo_dir  = manifestlib.repoLocalDir(repo_url)
    local src_path  = addon.path and (repo_dir .. '/' .. addon.path) or repo_dir
    local file_name = addon.path and (addon.path:match('[^\\/]+$') or spec.name) or spec.name

    -- Remove existing symlink/copy before re-linking
    local dest_dir = USERDIR .. (addon.type == 'library' and '/libraries/' or '/plugins/')
    util.rmrf(util.normPath(dest_dir .. file_name))

    M.fromLocal({
      plugin  = src_path,
      name    = file_name,
      library = (addon.type == 'library'),
    }):forward(promise)
  end)
  return promise
end

-- ---------------------------------------------------------------------------
-- postRun — run spec.run inside the installed plugin directory
-- ---------------------------------------------------------------------------
function M.postRun(spec)
  local promise = Promise.new()
  core.add_thread(function()
    local dir = USERDIR .. '/plugins/' .. spec.name
    local out, code = util.runInDir(spec.run, dir)
    if code ~= 0 then
      promise:reject(out)
    else
      promise:resolve()
    end
  end)
  return promise
end

return M

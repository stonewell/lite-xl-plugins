-- mod-version:3
local core      = require 'core'
local command   = require 'core.command'
local keymap    = require 'core.keymap'
local store     = require 'plugins.use_package.store'
local util      = require 'plugins.use_package.util'
local manifestlib = require 'plugins.use_package.manifest'
local installer = require 'plugins.use_package.installer'

store.init()

local M = {}

-- Internal registry — populated by use() calls in the user's init.lua
local _plugins  = {}
local _repos    = {}

-- Deferred :config / :bind hooks, flushed via core.add_thread after startup
local _pending   = {}
local _scheduled = false

local function schedule()
  if _scheduled then return end
  _scheduled = true
  core.add_thread(function()
    coroutine.yield()   -- let the rest of init.lua and plugin auto-load settle
    for _, fn in ipairs(_pending) do
      local ok, err = pcall(fn)
      if not ok then
        core.error('[use-package] hook error: %s', err)
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Register multi-plugin repo URLs (format: "url:tag").
-- Called before any use() declarations.
function M.repos(list)
  for _, r in ipairs(list) do
    table.insert(_repos, r)
  end
end

-- Declare a plugin.
-- plugin: string slug/URL/name, or table { plugin = '...', ... }
-- opts keys:
--   name         string   override install dir name
--   dependencies table    list of plugin specs to install first
--   run          string   post-install shell command
--   repo         string   pin to a specific registered repo URL
--   config       function runs after all plugins have loaded
--   bind         table    keybindings registered after load  { [key] = cmd }
function M.use(plugin, opts)
  opts = opts or {}
  local spec = type(plugin) == 'table' and plugin or { plugin = plugin }
  spec.plugin = spec.plugin or spec[1]
  spec.name   = spec.name or opts.name or util.plugName(spec.plugin)
  for _, k in ipairs({'run', 'repo', 'dependencies'}) do
    if opts[k] ~= nil then spec[k] = opts[k] end
  end

  table.insert(_plugins, spec)

  -- normalise onto spec so installSingle can access them after a hot-install
  if opts.bind then spec.bind = opts.bind end
  local configFn = (type(plugin) == 'table' and plugin.config) or opts.config
  spec.config = configFn  -- nil if none; table-form already carries it

  if spec.bind then
    schedule()
    table.insert(_pending, function() keymap.add(spec.bind) end)
  end
  if configFn then
    schedule()
    table.insert(_pending, configFn)
  end
end

-- ---------------------------------------------------------------------------
-- Install method auto-detection
-- ---------------------------------------------------------------------------
local function detectMethod(spec)
  if spec.installMethod then return spec.installMethod end
  if util.isLocalPath(spec.plugin)     then return 'local' end
  if util.slugify(spec.plugin) and not spec.repo then return 'git' end
  return 'repo'
end

-- ---------------------------------------------------------------------------
-- pluginExists — check for directory or single .lua file in plugins dir
-- ---------------------------------------------------------------------------
local function pluginExists(name)
  return util.fileExists(USERDIR .. '/plugins/' .. name)
      or util.fileExists(USERDIR .. '/plugins/' .. name .. '.lua')
end

-- ---------------------------------------------------------------------------
-- installSingle — install one plugin, dispatching to the right backend
-- ---------------------------------------------------------------------------
function M.installSingle(spec)
  spec.installMethod = detectMethod(spec)
  local name = spec.name

  local didpost = false
  local function onDone()
    if spec.run and not didpost then
      didpost = true
      installer.postRun(spec):done(onDone):fail(function(err)
        core.error('[use-package] post-run failed for %s: %s', name, err)
        spec.fullyInstalled = false
        store.addPlugin(spec)
      end)
      return
    end
    core.log('[use-package] installed %s', name)
    spec.fullyInstalled = true
    if spec.installMethod == 'repo' then
      -- record which repo hex this came from so updateRepo can find it
      local _, hex = manifestlib.searchAddon(name)
      spec.repo_hex = hex
    end
    store.addPlugin(spec)
    -- force a fresh load even if a previous attempt left a stale cache entry
    package.loaded['plugins.' .. name] = nil
    local ok, err = pcall(require, 'plugins.' .. name)
    if not ok then
      core.log('[use-package] %s loaded with warning: %s', name, err)
    end
    -- run config callback
    if spec.config then
      local ok2, err2 = pcall(spec.config)
      if not ok2 then
        core.error('[use-package] config error for %s: %s', name, err2)
      end
    end
    -- register keybindings
    if spec.bind then
      keymap.add(spec.bind)
    end
  end

  local function onFail(err)
    core.error('[use-package] failed to install %s: %s', name, err or '?')
    spec.fullyInstalled = false
    store.addPlugin(spec)
  end

  local method = spec.installMethod
  if method == 'git' then
    installer.fromGit(spec):done(onDone):fail(onFail)
  elseif method == 'local' then
    installer.fromLocal(spec):done(onDone):fail(onFail)
  else
    installer.fromRepo(spec):done(onDone):fail(onFail)
  end
end

-- ---------------------------------------------------------------------------
-- install — fetch repos, then install all missing plugins
-- ---------------------------------------------------------------------------
function M.install()
  core.add_thread(function()
    -- Step 1: download / update every registered repo manifest
    for _, repo in ipairs(_repos) do
      core.log('[use-package] setting up repo %s…', util.repoURL(repo))
      local out, code = manifestlib.downloadRepo(repo)
      if code ~= 0 then
        core.error('[use-package] could not fetch repo %s\n%s', repo, out)
        return   -- do not proceed if a repo fails
      end
    end

    -- Step 2: install declared plugins
    local function installSpec(spec)
      local stored = store.getPlugin(spec.plugin) or {}
      local already = stored.fullyInstalled and pluginExists(spec.name)
      if already then
        local method = stored.installMethod or detectMethod(spec)
        local function onDone(up_to_date)
          if up_to_date then
            core.log('[use-package] %s already up to date', spec.name)
          else
            core.log('[use-package] updated %s', spec.name)
          end
        end
        local function onFail(err)
          core.error('[use-package] update failed for %s: %s', spec.name, err or '?')
        end
        if method == 'git' then
          installer.updateGit(spec):done(onDone):fail(onFail)
        elseif method == 'repo' then
          installer.updateRepo(spec):done(onDone):fail(onFail)
        end
        -- 'local' plugins are managed by the dotfile repo; no-op
        return
      end
      M.installSingle(spec)
    end

    for _, spec in ipairs(_plugins) do
      if spec.dependencies then
        for _, dep in ipairs(spec.dependencies) do
          local dspec = type(dep) == 'string' and {plugin=dep} or dep
          dspec.name  = dspec.name or util.plugName(dspec.plugin)
          installSpec(dspec)
        end
      end
      installSpec(spec)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- update — update all installed plugins
-- ---------------------------------------------------------------------------
function M.update()
  core.add_thread(function()
    for _, spec in ipairs(_plugins) do
      local name   = spec.name
      local stored = store.getPlugin(spec.plugin)

      if not pluginExists(name) then
        M.installSingle(spec)
      elseif stored then
        local method = stored.installMethod or detectMethod(spec)
        core.log('[use-package] updating %s…', name)

        local function onDone(already)
          if already then
            core.log('[use-package] %s already up to date', name)
          else
            core.log('[use-package] updated %s', name)
            spec.fullyInstalled = true
            spec.installMethod  = method
            store.addPlugin(spec)
          end
        end
        local function onFail(err)
          core.error('[use-package] update failed for %s: %s', name, err or '?')
        end

        if method == 'repo' then
          installer.updateRepo(spec):done(onDone):fail(onFail)
        elseif method == 'git' then
          installer.updateGit(spec):done(onDone):fail(onFail)
        end
        -- 'local' plugins are managed by the dotfile repo; skip
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- reinstall — remove then re-install a single plugin by name
-- ---------------------------------------------------------------------------
function M.reinstall(spec)
  M.remove(spec)
  M.installSingle(spec)
end

-- ---------------------------------------------------------------------------
-- reinstallAll — reinstall every plugin that is tracked in the store
-- ---------------------------------------------------------------------------
function M.reinstallAll()
  for _, spec in ipairs(_plugins) do
    local stored = store.getPlugin(spec.plugin)
    if stored and stored.installMethod ~= 'local' and pluginExists(spec.name) then
      M.reinstall(spec)
    end
  end
end

-- ---------------------------------------------------------------------------
-- remove — delete installed files and drop from store
-- ---------------------------------------------------------------------------
function M.remove(spec)
  local slug = util.slugify(spec.plugin)
  local name = spec.name
  if slug then
    -- directory-based plugin
    os.remove(USERDIR .. '/plugins/' .. name)
  else
    -- single-file plugin
    os.remove(USERDIR .. '/plugins/' .. name .. '.lua')
  end
  store.removePlugin(spec.plugin)
  core.log('[use-package] removed %s', name)
end

-- ---------------------------------------------------------------------------
-- Lite-XL commands
-- ---------------------------------------------------------------------------
command.add(nil, {
  ['use-package:install'] = function() M.install() end,
  ['use-package:update']  = function() M.update() end,
  ['use-package:reinstall'] = function() M.reinstallAll() end,
})

return M

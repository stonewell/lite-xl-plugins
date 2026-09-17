local core = require 'core'
local command = require 'core.command'
local common = require 'core.common'
local config = require 'plugins.treesit.config'
local util = require 'plugins.treesit.util'
local ts = require 'libraries.tree_sitter'

local M = {
	defs = {},
	langCache = {},
	queryCache = {
		highlights = {},
	},
}

local soExt = PLATFORM == 'Windows' and '.dll' or '.so'

local LANGUAGE_FALLBACKS = {
	objcpp          = { 'objc', 'cpp', 'c' },
	objc            = { 'c' },
	cpp             = { 'c' },
	cuda            = { 'cpp', 'c' },
	arduino         = { 'cpp', 'c' },
	typescript      = { 'javascript' },
	tsx             = { 'typescript', 'javascript' },
	jsx             = { 'javascript' },
	vimdoc          = { 'vim' },
	markdown_inline = { 'markdown' },
}

-- Search for compiled parser binaries across standard and configured directories.
-- Handles .dll/.so on Windows, .so/.dylib on macOS, and .so on Linux/Unix.
local function findParser(dir, name)
	local dirs = util.getParserSearchDirs(dir, config)
	local extensions
	if PLATFORM == 'Windows' then
		extensions = { '.dll', '.so' }
	elseif PLATFORM == 'Mac OS X' then
		extensions = { '.so', '.dylib' }
	else
		extensions = { '.so' }
	end

	for _, d in ipairs(dirs) do
		for _, ext in ipairs(extensions) do
			local path = d .. '/' .. name .. ext
			if system.get_file_info(path) then return path end
		end
	end
	return nil
end

-- Pattern matching Neovim's EXTENDS_FORMAT in runtime/lua/vim/treesitter/query.lua
local EXTENDS_PATTERN = '^%s*;+%s*extends%s*$'

function M.addDef(defOptions)
	local def = {}

	assert(defOptions.name, 'Name is required for language definition')
	assert(not M.defs[defOptions.name], 'Duplicate language name')
	assert(defOptions.path, 'Path is required for language definition')

	def.name = defOptions.name
	def.files = defOptions.files

	local path = util.expandPath(defOptions.path)

	if defOptions.files and #defOptions.files > 0 then
		def.soFile = util.joinPath {
			path,
			defOptions.soFile and
				defOptions.soFile:gsub('{SOEXT}', soExt) or
				'parser' .. soExt
		}
	end

	def.queryFiles = {}

	-- queryFiles.highlights may be a string or an ordered list of strings
	local hl = defOptions.queryFiles and defOptions.queryFiles.highlights
	if type(hl) == 'table' then
		def.queryFiles.highlights = {}
		for _, p in ipairs(hl) do
			def.queryFiles.highlights[#def.queryFiles.highlights + 1] =
				util.joinPath { path, p }
		end
	else
		def.queryFiles.highlights = util.joinPath {
			path,
			hl or 'queries/highlights.scm'
		}
	end

	M.defs[#M.defs + 1] = def
	M.defs[def.name] = def
end

-- Convenience wrapper for nvim-treesitter's directory layout:
--   {root}/parser/{name}.dll   — compiled parser
--   {root}/queries/{name}/highlights.scm  — often has ; extends
--   {runtimeDir}/queries/{name}/highlights.scm — Neovim bundled base
--
-- If runtimeDir is provided, addNvimLang peeks at the nvim-treesitter query
-- file; when it starts with "; extends", the runtime base is prepended so
-- the base captures are not lost.
function M.addNvimLang(opts)
	local rootStr = opts.root or config.nvimTsRoot
	assert(rootStr, 'root is required for addNvimLang')
	assert(opts.name, 'name is required for addNvimLang')

	local root       = util.expandPath(rootStr)
	local runtimeDir = (opts.runtimeDir or config.nvimRuntimeDir) and util.expandPath(opts.runtimeDir or config.nvimRuntimeDir)
	local parserDir  = opts.parserDir and util.expandPath(opts.parserDir) or (root .. '/parser')
	local name       = opts.name

	assert(not M.defs[name], 'Duplicate language name: ' .. name)

	-- Search for parser: try requested parserName, then name, then check fallbacks
	local parserName = opts.parserName or name
	local soFile     = findParser(parserDir, parserName)
	local queryName  = opts.queryName or parserName
	local fallbacks  = LANGUAGE_FALLBACKS[name]

	if not soFile and not opts.parserName and fallbacks then
		for _, fb in ipairs(fallbacks) do
			local fbFile = findParser(parserDir, fb)
			if fbFile then
				soFile     = fbFile
				parserName = fb
				queryName  = opts.queryName or fb
				break
			end
		end
	end

	-- Resolve query file
	local nvimQueryPath = root .. '/queries/' .. queryName .. '/highlights.scm'
	local rtQueryPath   = runtimeDir and (runtimeDir .. '/queries/' .. queryName .. '/highlights.scm')
	if not system.get_file_info(nvimQueryPath) and rtQueryPath and system.get_file_info(rtQueryPath) then
		nvimQueryPath = rtQueryPath
	end

	-- If query still not found and fallback chain exists, try queries for fallbacks
	if not system.get_file_info(nvimQueryPath) and fallbacks then
		for _, fb in ipairs(fallbacks) do
			local fbQ   = root .. '/queries/' .. fb .. '/highlights.scm'
			local fbRtQ = runtimeDir and (runtimeDir .. '/queries/' .. fb .. '/highlights.scm')
			if system.get_file_info(fbQ) then
				nvimQueryPath = fbQ
				queryName     = fb
				break
			elseif fbRtQ and system.get_file_info(fbRtQ) then
				nvimQueryPath = fbRtQ
				queryName     = fb
				break
			end
		end
	end

	-- Peek at the nvim-treesitter query to see if it uses ; extends
	local usesExtends = false
	local f = io.open(nvimQueryPath)
	if f then
		local firstLine = f:read '*l'
		if firstLine and firstLine:match(EXTENDS_PATTERN) then
			usesExtends = true
		end
		f:close()
	end

	local def = {
		name          = name,
		langName      = parserName,
		parserDir     = parserDir,
		files         = opts.files,
		soFile        = soFile,
		queryFiles    = {},
		fallbackChain = fallbacks,
	}

	if usesExtends and runtimeDir then
		def.queryFiles.highlights = {
			runtimeDir .. '/queries/' .. queryName .. '/highlights.scm',
			nvimQueryPath,
		}
	else
		def.queryFiles.highlights = nvimQueryPath
	end

	M.defs[#M.defs + 1] = def
	M.defs[def.name] = def
end

function M.findDef(filename)
	if not filename then return nil end
	local bestScore = 0
	local bestDef

	for i = #M.defs, 1, -1 do
		local def = M.defs[i]
		if not def.files then goto continue end

		for _, pattern in ipairs(def.files) do
			local s, e = filename:find(pattern)
			if not s then goto continue end

			local score = e - s
			if score > bestScore then
				bestScore = score
				bestDef = def
			end

			::continue::
		end

		::continue::
	end

	return bestDef
end

function M.getLang(def)
	local lang = M.langCache[def.name]
	if lang then
		return lang
	end

	local soFile = def.soFile
	local langName = def.langName or def.name

	if not soFile or not system.get_file_info(soFile) then
		-- Dynamic check in case parser was installed after startup
		local freshFile = findParser(def.parserDir, def.name)
		if freshFile then
			soFile = freshFile
			langName = def.name
			def.soFile = soFile
			def.langName = langName
		elseif def.fallbackChain then
			for _, fb in ipairs(def.fallbackChain) do
				local fbFile = findParser(def.parserDir, fb)
				if fbFile then
					soFile = fbFile
					langName = fb
					def.soFile = soFile
					def.langName = langName
					break
				end
			end
		end
	end

	if not soFile or not system.get_file_info(soFile) then
		core.log_quiet('treesit: parser not found for %s, falling back to built-in syntax', def.name)
		return nil
	end

	local ok, result = pcall(ts.Language.load, soFile, langName)
	if not ok then
		core.log_quiet('treesit: error loading language %s from %s: %s', def.name, tostring(soFile), tostring(result))
		return nil
	end

	M.langCache[def.name] = result
	core.log('Loaded language ' .. def.name .. ' (using parser ' .. langName .. ')')

	return result
end

-- Load a single query file into the builder table.
-- Strips leading ; extends lines (Neovim meta-directive, not valid tree-sitter syntax).
-- Handles ; inherits: lang1, lang2 with spaces around commas.
local function loadQueryFile(path, builder, queryType)
	local f = io.open(path)
	if not f then return false end

	-- Scan header comment block for modelines
	while true do
		local head = f:read '*l'
		if not head or not head:match '%s*;' then
			break
		end

		-- Skip ; extends lines (strip from output)
		if head:match(EXTENDS_PATTERN) then
			goto continue
		end

		-- Handle ; inherits: lang1, lang2  (spaces after commas are ok)
		local rest = head:match '%s*;+%s*inherits%s*:%s*(.*)'
		if rest then
			for name in rest:gmatch '[%l_]+' do
				local inheritDef = M.defs[name]
				if not inheritDef then
					local root = config.nvimTsRoot and util.expandPath(config.nvimTsRoot)
					local runtimeDir = config.nvimRuntimeDir and util.expandPath(config.nvimRuntimeDir)
					local queryPath = root and (root .. '/queries/' .. name .. '/' .. queryType .. '.scm')
					local rtQueryPath = runtimeDir and (runtimeDir .. '/queries/' .. name .. '/' .. queryType .. '.scm')
					local foundPath
					if queryPath and system.get_file_info(queryPath) then
						foundPath = queryPath
					elseif rtQueryPath and system.get_file_info(rtQueryPath) then
						foundPath = rtQueryPath
					end
					if foundPath then
						inheritDef = {
							name = name,
							queryFiles = { [queryType] = foundPath },
						}
						M.defs[name] = inheritDef
						M.defs[#M.defs + 1] = inheritDef
					end
				end

				if not inheritDef then
					core.warn(
						'Could not find language %s to inherit queries from. \z
						Syntax highlighting may be incomplete.',
						name
					)
					goto continue
				end

				builder[#builder + 1] = '; TREESIT: INHERIT ' .. name .. '\n'
				builder[#builder + 1] = M.getQuery(inheritDef, queryType)

				::continue::
			end
		end

		::continue::
	end

	f:seek('set', 0)
	local content = f:read '*a'
	f:close()
	-- Strip all ; extends lines (Neovim meta-directive, not valid tree-sitter syntax)
	content = content:gsub('[^\n]*;+%s*extends%s*\n', '')
	content = content:gsub('[^\n]*;+%s*extends%s*$', '')
	builder[#builder + 1] = content
	return true
end

function M.getQuery(def, queryType)
	local query = M.queryCache[queryType][def.name]
	if query then
		return query
	end

	local paths = def.queryFiles[queryType]
	-- Normalise to a list
	if type(paths) == 'string' then
		paths = { paths }
	end

	if not paths or #paths == 0 then
		core.error('No query files configured for ' .. def.name .. ' ' .. queryType)
		return nil
	end

	local builder = { '; TREESIT: BEGIN ' .. def.name .. '\n' }

	for _, path in ipairs(paths) do
		local ok = loadQueryFile(path, builder, queryType)
		if not ok then
			core.error('Error loading ' .. def.name .. ' ' .. queryType .. ' query: ' .. path)
			return nil
		end
	end

	builder[#builder + 1] = '; TREESIT: END ' .. def.name .. '\n'

	query = table.concat(builder)
	M.queryCache[queryType][def.name] = query
	core.log('Loaded ' .. def.name .. ' ' .. queryType .. ' query')

	return query
end

local queryRecents = {}

command.add(nil, {
	['treesit:view-highlights-query'] = function()
		core.command_view:enter('View highlights query for language', {
			submit = function(name)
				local def = M.defs[name]
				if not def then
					core.error('No such language %s', name)
					return
				end

				local doc = core.open_doc('highlights.scm')
				core.root_view:open_doc(doc)
				doc:insert(1, 1, M.getQuery(def, 'highlights'))
				doc.new_file = false
				doc:clean()
			end,

			suggest = function(name)
				local names = {}
				for _, def in ipairs(M.defs) do
					names[#names + 1] = def.name
				end

				return common.fuzzy_match_with_recents(names, queryRecents, name)
			end,
		})
	end,
})

return M

local common = require 'core.common'
local M = {}

function M.expandPath(p)
	if not p then return nil end

	-- Expand Windows environment variables: %VAR%
	p = p:gsub('%%([%a_][%w_]*)%%', function(var)
		local val = os.getenv(var)
		return (val and #val > 0) and val:gsub('\\', '/') or ('%' .. var .. '%')
	end)

	-- Expand Unix environment variables: ${VAR} and $VAR with XDG fallbacks
	local function getUnixEnv(var)
		local val = os.getenv(var)
		if val and #val > 0 then
			return val:gsub('\\', '/')
		elseif var == 'XDG_DATA_HOME' then
			local h = os.getenv('HOME')
			return h and (h:gsub('\\', '/') .. '/.local/share') or '~/.local/share'
		elseif var == 'XDG_CONFIG_HOME' then
			local h = os.getenv('HOME')
			return h and (h:gsub('\\', '/') .. '/.config') or '~/.config'
		end
		return nil
	end

	p = p:gsub('%${([%a_][%w_]*)}', function(var)
		local val = getUnixEnv(var)
		return val or ('${' .. var .. '}')
	end)
	p = p:gsub('%$([%a_][%w_]*)', function(var)
		local val = getUnixEnv(var)
		return val or ('$' .. var)
	end)

	-- Expand ~
	p = common.home_expand(p)

	-- Normalize slashes
	p = p:gsub('\\', '/')
	return p
end

local function findFirstExistingDir(candidates)
	for _, c in ipairs(candidates) do
		local exp = M.expandPath(c)
		local info = system.get_file_info(exp)
		if info and info.type == 'dir' then
			return exp
		end
	end
	return nil
end

--- Auto-detect nvim-treesitter plugin directory across Windows, Linux, and macOS
function M.findNvimTsRoot()
	local candidates
	if PLATFORM == 'Windows' then
		candidates = {
			'%LOCALAPPDATA%/nvim-data/lazy/nvim-treesitter',
			'~/nvim-data/lazy/nvim-treesitter',
			'~/.local/share/nvim/lazy/nvim-treesitter',
			'%LOCALAPPDATA%/nvim-data/site/pack/packer/start/nvim-treesitter',
		}
	else
		candidates = {
			'$XDG_DATA_HOME/nvim/lazy/nvim-treesitter',
			'~/.local/share/nvim/lazy/nvim-treesitter',
			'~/.local/share/nvim/site/pack/packer/start/nvim-treesitter',
			'~/.local/share/nvim/site/pack/plugins/start/nvim-treesitter',
			'~/.vim/plugged/nvim-treesitter',
		}
	end

	local found = findFirstExistingDir(candidates)
	if found then return found end

	return PLATFORM == 'Windows'
		and M.expandPath('%LOCALAPPDATA%/nvim-data/lazy/nvim-treesitter')
		or M.expandPath('~/.local/share/nvim/lazy/nvim-treesitter')
end

--- Auto-detect Neovim runtime directory ($VIMRUNTIME) across Windows, Linux, and macOS
function M.findNvimRuntimeDir()
	local candidates = {}
	local vimruntime = os.getenv('VIMRUNTIME')
	if vimruntime and #vimruntime > 0 then
		candidates[#candidates + 1] = vimruntime
	end

	if PLATFORM == 'Windows' then
		-- Scoop (user, global, or standard locations)
		candidates[#candidates + 1] = '%SCOOP%/apps/neovim/current/share/nvim/runtime'
		candidates[#candidates + 1] = '%SCOOP_GLOBAL%/apps/neovim/current/share/nvim/runtime'
		candidates[#candidates + 1] = '~/scoop/apps/neovim/current/share/nvim/runtime'
		candidates[#candidates + 1] = '%ProgramData%/scoop/apps/neovim/current/share/nvim/runtime'
		candidates[#candidates + 1] = 'C:/scoop/apps/neovim/current/share/nvim/runtime'
		-- Winget / MSI / Standard
		candidates[#candidates + 1] = '%ProgramFiles%/Neovim/share/nvim/runtime'
		candidates[#candidates + 1] = '%ProgramFiles(x86)%/Neovim/share/nvim/runtime'
		candidates[#candidates + 1] = '%LOCALAPPDATA%/Programs/Neovim/share/nvim/runtime'
		-- Chocolatey
		candidates[#candidates + 1] = 'C:/tools/neovim/share/nvim/runtime'
		candidates[#candidates + 1] = '%ProgramData%/chocolatey/lib/neovim/tools/neovim/share/nvim/runtime'
	elseif PLATFORM == 'Mac OS X' then
		-- Homebrew (Apple Silicon & Intel), MacPorts, Neovim.app
		candidates[#candidates + 1] = '/opt/homebrew/share/nvim/runtime'
		candidates[#candidates + 1] = '/usr/local/share/nvim/runtime'
		candidates[#candidates + 1] = '/opt/local/share/nvim/runtime'
		candidates[#candidates + 1] = '/Applications/Neovim.app/Contents/Resources/runtime'
	else
		-- Linux / BSD / Unix
		candidates[#candidates + 1] = '/usr/share/nvim/runtime'
		candidates[#candidates + 1] = '/usr/local/share/nvim/runtime'
		candidates[#candidates + 1] = '~/.local/share/nvim/runtime'
		candidates[#candidates + 1] = '/snap/nvim/current/usr/share/nvim/runtime'
		candidates[#candidates + 1] = '/var/lib/flatpak/app/io.neovim.nvim/current/active/files/share/nvim/runtime'
	end

	return findFirstExistingDir(candidates)
end

--- Auto-detect Neovim bundled parser directory across Windows, Linux, and macOS
function M.findNvimBuiltinParserDir(runtimeDir)
	local candidates = {}
	if runtimeDir then
		candidates[#candidates + 1] = runtimeDir .. '/parser'
		candidates[#candidates + 1] = runtimeDir .. '/../lib/nvim/parser'
		candidates[#candidates + 1] = runtimeDir .. '/../../lib/nvim/parser'
	end

	if PLATFORM == 'Windows' then
		-- Scoop (user, global, or standard locations)
		candidates[#candidates + 1] = '%SCOOP%/apps/neovim/current/lib/nvim/parser'
		candidates[#candidates + 1] = '%SCOOP_GLOBAL%/apps/neovim/current/lib/nvim/parser'
		candidates[#candidates + 1] = '~/scoop/apps/neovim/current/lib/nvim/parser'
		candidates[#candidates + 1] = '%ProgramData%/scoop/apps/neovim/current/lib/nvim/parser'
		candidates[#candidates + 1] = 'C:/scoop/apps/neovim/current/lib/nvim/parser'
		-- Winget / MSI / Standard
		candidates[#candidates + 1] = '%ProgramFiles%/Neovim/lib/nvim/parser'
		candidates[#candidates + 1] = '%LOCALAPPDATA%/Programs/Neovim/lib/nvim/parser'
	elseif PLATFORM == 'Mac OS X' then
		candidates[#candidates + 1] = '/opt/homebrew/lib/nvim/parser'
		candidates[#candidates + 1] = '/usr/local/lib/nvim/parser'
	else
		candidates[#candidates + 1] = '/usr/lib/nvim/parser'
		candidates[#candidates + 1] = '/usr/lib64/nvim/parser'
		candidates[#candidates + 1] = '/usr/lib/x86_64-linux-gnu/nvim/parser'
		candidates[#candidates + 1] = '/usr/local/lib/nvim/parser'
	end

	return findFirstExistingDir(candidates)
end

--- Collect all directories where Tree-sitter parsers could be installed
function M.getParserSearchDirs(extraDir, cfg)
	local dirs = {}
	local seen = {}
	local function add(p)
		if not p then return end
		local exp = M.expandPath(p)
		if exp and not seen[exp] then
			seen[exp] = true
			dirs[#dirs + 1] = exp
		end
	end

	add(extraDir)
	if cfg then
		if cfg.nvimTsRoot then
			add(cfg.nvimTsRoot .. '/parser')
		end
		if cfg.nvimBuiltinParserDir then
			add(cfg.nvimBuiltinParserDir)
		end
		if cfg.nvimRuntimeDir then
			add(cfg.nvimRuntimeDir .. '/parser')
			add(cfg.nvimRuntimeDir .. '/../../lib/nvim/parser')
		end
	end

	if PLATFORM == 'Windows' then
		add('%LOCALAPPDATA%/nvim-data/lazy/nvim-treesitter/parser')
		add('%LOCALAPPDATA%/nvim-data/site/parser')
		add('~/nvim-data/lazy/nvim-treesitter/parser')
		add('~/.local/share/nvim/lazy/nvim-treesitter/parser')
	else
		add('$XDG_DATA_HOME/nvim/lazy/nvim-treesitter/parser')
		add('~/.local/share/nvim/lazy/nvim-treesitter/parser')
		add('$XDG_DATA_HOME/nvim/site/parser')
		add('~/.local/share/nvim/site/parser')
		add('~/.local/share/nvim/site/pack/packer/start/nvim-treesitter/parser')
	end

	return dirs
end

function M.joinPath(parts)
	local str = ''
	local sepPattern = string.format('%s$', '%' .. PATHSEP)
	for i, part in ipairs(parts) do
		local sepMatch = part:match(sepPattern)
		str = str .. part .. (sepMatch or i == #parts and '' or PATHSEP)
	end
	str = str:gsub(string.format('%s$', '%' .. PATHSEP), '')

	return str
end

function M.flatten(parts, dest)
	dest = dest or {}

	for _, part in ipairs(parts) do
		if type(part) == 'table' then
			M.flatten(part, dest)
		else
			dest[#dest + 1] = part
		end
	end

	return dest
end

function M.input(lines)
	return function(_, point)
		if point:row() < #lines then
			return lines[point:row() + 1], point:column() + 1
		else
			return nil
		end
	end
end

return M

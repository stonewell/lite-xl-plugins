local common = require 'core.common'
local config = require 'core.config'
local util   = require 'plugins.treesit.util'

local defaultTsRoot           = util.findNvimTsRoot()
local defaultRuntimeDir       = util.findNvimRuntimeDir()
local defaultBuiltinParserDir = util.findNvimBuiltinParserDir(defaultRuntimeDir)

local defaults = {
	useFallbackColors    = true,
	warnFallbackColors   = true,
	maxParseTime         = 2000,
	nvimTsRoot           = defaultTsRoot,
	nvimRuntimeDir       = defaultRuntimeDir,
	nvimBuiltinParserDir = defaultBuiltinParserDir,
}

local spec = {
	name = 'Treesit',
	{
		label       = 'Use fallback colors',
		description = 'Set fallbacks for missing colors',
		path        = 'useFallbackColors',
		type        = 'toggle',
	},
	{
		label       = 'Warn fallback colors',
		description = 'Warn when fallback colors are used',
		path        = 'warnFallbackColors',
		type        = 'toggle',
	},
	{
		label       = 'The below options are meant for advanced use only.',
		path        = '',
		type        = 'button',
		icon        = '!',
	},
	{
		label       = 'Maximum parse time',
		description = 'Maximum time spent parsing before deferring it (in µs). Set this to 0 to disable deferring',
		path        = 'maxParseTime',
		type        = 'number',
		min         = 0,
		step        = 1,
	},
	{
		label       = 'Neovim tree-sitter root',
		description = 'Path to nvim-treesitter plugin root (e.g. %LOCALAPPDATA%/nvim-data/lazy/nvim-treesitter)',
		path        = 'nvimTsRoot',
		type        = 'string',
	},
	{
		label       = 'Neovim runtime directory',
		description = 'Path to Neovim $VIMRUNTIME, used to load base queries for languages whose nvim-treesitter query uses ; extends',
		path        = 'nvimRuntimeDir',
		type        = 'string',
	},
	{
		label       = 'Neovim bundled parser directory',
		description = 'Path to the parser/ dir shipped with Neovim itself (e.g. lib/nvim/parser). Used for the ~7 languages bundled with Neovim before any :TSInstall.',
		path        = 'nvimBuiltinParserDir',
		type        = 'string',
	},
}

for _, option in ipairs(spec) do
	option.default = defaults[option.path]
end

defaults.config_spec    = spec
config.plugins.treesit  = common.merge(defaults, config.plugins.treesit)

return config.plugins.treesit

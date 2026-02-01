local M = {}

-- Manifest file names for each type
M.MANIFEST_FILES = {
	package = { "package.json" },
	crates = { "Cargo.toml" },
	pubspec = { "pubspec.yaml", "pubspec.yml" },
	composer = { "composer.json" },
	go = { "go.mod" },
}

-- Lock file candidates for each manifest type
M.LOCK_CANDIDATES = {
	composer = { "composer.lock" },
	pubspec = { "pubspec.lock" },
	package = { "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml" },
	crates = { "Cargo.lock" },
	go = { "go.sum" },
}

-- Manifest file patterns (flattened from MANIFEST_FILES)
M.MANIFEST_PATTERNS = {
	"package.json",
	"Cargo.toml",
	"pubspec.yaml",
	"pubspec.yml",
	"composer.json",
	"go.mod",
}

-- Lock file patterns for autocmd watching
M.LOCK_FILE_PATTERNS = {
	"pubspec.lock",
	"Cargo.lock",
	"package-lock.json",
	"yarn.lock",
	"pnpm-lock.yaml",
	"composer.lock",
	"go.sum",
}

-- Manifest key mapping
M.MANIFEST_KEYS = {
	["package.json"] = "package",
	["Cargo.toml"] = "crates",
	["pubspec.yaml"] = "pubspec",
	["pubspec.yml"] = "pubspec",
	["composer.json"] = "composer",
	["go.mod"] = "go",
}

-- Lock file search patterns for each manifest type
M.LOCK_SEARCH_PATTERNS = {
	pubspec = "^%s+([%w_%-]+)%s*:",
	crates = 'name%s*=%s*"([%w_%-]+)"',
	package = '"([%w_%-@/]+)"',
	composer = '"([%w_%-/]+)"',
	go = "([%w%.%-_/]+)",
}

-- Section names for each manifest type (used for dependency scope detection)
M.SECTION_NAMES = {
	pubspec = { "dependencies", "dev_dependencies", "dependency_overrides" },
	package = { "dependencies", "devDependencies", "dev_dependencies" },
	composer = { "require", "require-dev", "require_dev" },
	crates = { "dependencies", "dev-dependencies", "build-dependencies" },
	go = { "require" },
}

-- Action module mapping for each manifest type
M.ACTION_MAP = {
	package = "lvim-dependencies.actions.package",
	crates = "lvim-dependencies.actions.cargo",
	pubspec = "lvim-dependencies.actions.pubspec",
	composer = "lvim-dependencies.actions.composer",
	go = "lvim-dependencies.actions.go",
}

return M

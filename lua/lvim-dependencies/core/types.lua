-- lvim-dependencies/core/types.lua
-- Centralized type definitions for the entire project

---@diagnostic disable: undefined-doc-name

-- ============================================================================
-- Async primitives
-- ============================================================================

---@alias async_callback fun(...: any)

---@class async_task
---@field fun fun(callback: async_callback)

---@alias async_task_function fun(callback: async_callback)

---@class async_file_read_result
---@field err string|nil
---@field content string|nil

---@class async_all_result
---@field results table
---@field error string|nil

---@class async_settled_result
---@field results table[] List of {err, ...} tuples

-- ============================================================================
-- System types
-- ============================================================================

---@class SystemCompleted
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string

---@class SystemOpts
---@field cwd? string
---@field env? table<string, string>
---@field stdin? string
---@field timeout? integer

-- ============================================================================
-- Cache types
-- ============================================================================

---@class CacheEntry
---@field data table<string, any>
---@field metadata? table<string, any>
---@field loader? table
---@field installer? table
---@field temp? table

---@class Cache
---@field declared table<string, CacheEntry>
---@field installed table<string, CacheEntry>
---@field latest table<string, CacheEntry>
---@field virtual_text table<string, CacheEntry>
---@field manifest table<string, CacheEntry>

---@alias CacheType "declared"|"installed"|"latest"|"virtual_text"|"manifest"

-- ============================================================================
-- File operation types
-- ============================================================================

---@class FileChange
---@field start0 integer Start line index (0-based)
---@field end0 integer End line index (0-based)
---@field lines string[] Replacement lines

-- ============================================================================
-- Event bus types
-- ============================================================================

---@alias EventHandler fun(...: any)

---@alias PreDefinedEvents
---| "declared:updated"
---| "installed:updated"
---| "latest:updated"
---| "manager:loaded"
---| "manager:unloaded"
---| "plugin:ready"
---| "cache:cleared"
---| "debug"

-- ============================================================================
-- Core init types
-- ============================================================================

---@alias ManagerModuleType "declared"|"latest"|"installer"|"manifest"|"virtual_text"

-- ============================================================================
-- Action types (shared between managers)
-- ============================================================================

---@class VersionData
---@field versions string[]
---@field current string|nil
---@field section string|nil

---@class UpdateOptions
---@field version string
---@field from_ui? boolean
---@field scope? string
---@field callback? InstallerCallback

---@class DeleteOptions
---@field from_ui? boolean
---@field callback? InstallerCallback

---@class InstallResult
---@field ok boolean
---@field msg string

---@class PackageInfo
---@field name string
---@field line integer

-- ============================================================================
-- Metrics types
-- ============================================================================

---@class CacheStats
---@field hits integer
---@field misses integer
---@field expiries integer
---@field clears integer
---@field by_manager table<string, {hits: integer, misses: integer}>

---@class SessionStats
---@field hits integer
---@field misses integer
---@field files_opened integer
---@field start_time integer

---@class PerformanceStats
---@field load_times number[]
---@field by_package table<string, {count: integer, total: number, last_access: integer}>
---@field slowest {name: string, time: number}

---@class ErrorsStats
---@field total integer
---@field by_manager table<string, integer>
---@field by_type table<string, integer>

---@class OperationsStats
---@field total_loads integer
---@field total_saves integer
---@field total_opens integer

---@class BuffersStats
---@field active integer
---@field with_virtual_text integer

---@class TimestampsStats
---@field start integer
---@field last_reset integer

---@class TimelineStats
---@field operations table[]
---@field max_entries integer

---@class TrendsStats
---@field hourly table<integer, integer>
---@field daily table<integer, integer>

---@class MetricsStats
---@field cache CacheStats
---@field session SessionStats
---@field by_level table<integer, integer>
---@field msg_types table<string, integer>
---@field msg_examples table<string, {messages: string[], timestamp: integer}>
---@field performance PerformanceStats
---@field errors ErrorsStats
---@field operations OperationsStats
---@field buffers BuffersStats
---@field timestamps TimestampsStats
---@field timeline TimelineStats
---@field trends TrendsStats

---@class CurrentMeasure
---@field name string|nil
---@field start integer

-- ============================================================================
-- Package loader types
-- ============================================================================

---@class PackageResult
---@field manifest string The manager type (e.g., "pubspec", "cargo")
---@field package string The package name
---@field declared table|nil The declared package data from the manifest file
---@field installed string|nil The currently installed version
---@field latest LatestPackageInfo|nil The latest available version (table with version and metadata)
---@field installed_err string|nil Error message from installed lookup
---@field latest_err string|nil Error message from latest lookup

---@class PackageLoaderOptions
---@field initial? boolean Whether this is an initial load

---@alias PackageLoaderCallback fun(result: PackageResult)

-- ============================================================================
-- Version types
-- ============================================================================

---@alias VersionParseResult {major: number, minor: number, patch: number, prerelease: string, build: string, original: string}

-- ============================================================================
-- Registry types
-- ============================================================================

---@class RegistryResponseConfig
---@field version_path? string[] Path to version in JSON response
---@field versions_path? string[] Path to versions array in JSON response

---@class RegistryConfig
---@field base_url? string Base URL for registry
---@field package_endpoint? string Endpoint template with %s for package name
---@field response? RegistryResponseConfig Response parsing configuration

---@class ApiConfig
---@field timeout? integer HTTP timeout in seconds

-- ============================================================================
-- Dependency types
-- ============================================================================

---@class DependencyTypeDef
---@field detect fun(version: any): boolean
---@field extract? fun(version: any, target: table)
---@field format? fun(dep: table): VirtualTextChunk[]
---@field format_hover? fun(dep: table, latest: string|nil, metadata: table|nil): string[]

-- ============================================================================
-- Manager manifest types
-- ============================================================================

---@class ManagerManifest
---@field key string Unique identifier for the manager (e.g., "pubspec", "cargo")
---@field dependency_types table<string, DependencyTypeDef> Map of dependency type names to their definitions
---@field file_patterns? string[] File patterns to detect this manager
---@field lock_files? string[] Lock file names
---@field dependency_sections? string[] Sections containing dependencies
---@field special_keys? string[] Keys that are not packages
---@field package_patterns? table<string, string> Patterns to extract package names
---@field default_registry? string Default registry URL
---@field registry? RegistryConfig Registry configuration
---@field commands? table<string, table<string, string[]>> Commands for package management
---@field project_type_detectors? table<string, string> Patterns to detect project type
---@field api? ApiConfig API configuration
---@field package_validation? {pattern: string, min_length: integer, max_length: integer}
---@field formatting? {indent: string, sort_dependencies: boolean}
---@field virtual_text? {position: string, priority: integer}

-- ============================================================================
-- Manager-specific dependency types
-- ============================================================================

---@class PubspecGitDependency
---@field url string
---@field ref? string
---@field path? string

---@class PubspecPathDependency
---@field location string

---@class PubspecHostedDependency
---@field name string
---@field version? string
---@field url? string

---@class CargoGitDependency
---@field url string
---@field branch? string
---@field tag? string
---@field rev? string

---@class CargoPathDependency
---@field location string

---@class CargoWorkspaceDependency
---@field workspace boolean
---@field version? string

-- ============================================================================
-- Manager-specific declared package types
-- ============================================================================

---@class PubspecDeclaredPackage
---@field name string Package name
---@field type string Dependency type (e.g., "registry", "git", "path", "sdk")
---@field declared? string|nil The declared version or reference
---@field raw? any Raw version/table from pubspec.yaml
---@field git? PubspecGitDependency Git repository info
---@field path? PubspecPathDependency Local path dependency
---@field sdk? string SDK dependency (e.g., "flutter")
---@field hosted? PubspecHostedDependency Hosted package info

---@class CargoDeclaredPackage
---@field name string Package name
---@field type string Dependency type (e.g., "registry", "git", "path", "workspace")
---@field declared? string|nil The declared version or reference
---@field raw? any Raw version/table from Cargo.toml
---@field git? CargoGitDependency Git repository info
---@field path? CargoPathDependency Local path dependency
---@field workspace? CargoWorkspaceDependency Workspace dependency
---@field features? string[] Enabled features
---@field optional? boolean Whether dependency is optional
---@field default_features? boolean Whether to include default features

-- ============================================================================
-- Manager-specific manifest types
-- ============================================================================

--- Pubspec-specific manifest extending base with SDK packages
---@class PubspecManifest: ManagerManifest
---@field sdk_packages? table<string, boolean> SDK packages that skip registry lookup

--- Cargo-specific manifest (no additional fields beyond base)
---@class CargoManifest: ManagerManifest

-- ============================================================================
-- State types
-- ============================================================================

---@class BufferEventData
---@field type string Type of event (e.g., "opened", "saved", "modified")
---@field timestamp integer Unix timestamp when event occurred
---@field filename string Full path to the buffer file
---@field filetype string Filetype of the buffer
---@field lines integer Number of lines in the buffer
---@field modified boolean Whether buffer has unsaved changes
---@field extra table Additional event-specific data

---@class StateBufferData
---@field filename string Full path to the buffer file
---@field filetype string Filetype of the buffer
---@field last_opened? integer Timestamp when buffer was last opened
---@field last_saved? integer Timestamp when buffer was last saved
---@field last_modified? integer Timestamp when buffer was last modified
---@field last_closed? integer Timestamp when buffer was last closed
---@field last_entered? integer Timestamp when buffer was last entered
---@field last_accessed? integer Timestamp when buffer was last accessed
---@field last_event? string Last event type that occurred
---@field count_open? integer Number of times buffer was opened
---@field count_save? integer Number of times buffer was saved
---@field count_modification? integer Number of modifications
---@field count_filetype_changes? integer Number of filetype changes
---@field count_enter? integer Number of times buffer was entered
---@field is_open? boolean Whether buffer is currently open
---@field modified? boolean Whether buffer has unsaved changes
---@field initial_load_complete? boolean Whether initial package loading is complete
---@field is_loading? boolean Whether package is currently loading
---@field pending_dep? string Pending dependency being processed
---@field pending_lnum? integer Line number where package will be inserted
---@field pending_scope? string Section where package will be inserted
---@field pending_anchor_id? integer Extmark ID for pending anchor
---@field skip_next_check boolean|nil

---@class NewPackage
---@field name string Package name
---@field line integer Line number where package is declared
---@field info? table Additional package info from manifest

---@class ChangedPackage
---@field name string Package name
---@field old_version string|nil Previously declared version
---@field new_version string Newly declared version

---@class PackageChanges
---@field new NewPackage[] List of newly added packages
---@field changed ChangedPackage[] List of packages with version changes
---@field removed string[] List of removed package names

-- ============================================================================
-- Virtual text types
-- ============================================================================

---@class VirtualTextChunk
---@field [1] string The text to display
---@field [2] string The highlight group

---@class VirtualTextHandlers
---@field get_loaded_packages fun(buf: integer): table<string, {declared: any, installed: string|nil, latest: string|nil}>
---@field find_package_line fun(buf: integer, pkg: string): integer|nil
---@field move_virt_texts_only fun(buf: integer)
---@field check_for_new_packages fun(buf: integer)
---@field display_loading fun(buf: integer, manifest_type: string, packages: table<string, any>, is_initial?: boolean)
---@field update_package fun(buf: integer, package_data: PackageResult)
---@field display_loading_for_package fun(buf: integer, manifest_type: string, package_info: NewPackage, mode: string)
---@field remove_package fun(buf: integer, package_name: string)
---@field clear_buffer fun(buf: integer)
---@field on_new_packages? fun(buf: integer, new_packages: NewPackage[])

---@class PackageRecord
---@field package string Package name
---@field manifest_type string Manager type
---@field installed string|nil Currently installed version
---@field latest table|nil Latest version info (table with version and metadata)
---@field installed_err string|nil Error from installed lookup
---@field latest_err string|nil Error from latest lookup
---@field declared table|nil Original declared data
---@field declared_version string|nil Extracted declared version
---@field is_transient boolean Whether this is a temporary loading indicator
---@field created_at? integer Timestamp when record was created
---@field extmark_id? integer ID of the extmark if placed
---@field last_line? integer Last known line number for this package

---@class VirtualTexts
---@field [integer] table<string|integer, any> Buffer to (package name to PackageRecord) plus .declared, .manifest_type

---@class VirtualTextDef
---@field namespace integer
---@field _moving table<integer, boolean>
---@field _updating table<integer, boolean>
---@field _handlers VirtualTextHandlers
---@field virt_texts VirtualTexts
---@field move_virt_texts_only fun(buf: integer)
---@field check_for_new_packages fun(buf: integer)
---@field get_loaded_packages fun(buf: integer): table<string, {declared: any, installed: string|nil, latest: table|nil}>
---@field find_package_line fun(buf: integer, package_name: string): integer|nil
---@field remove_package fun(buf: integer, package_name: string)
---@field clear_buffer fun(buf: integer)
---@field display_loading fun(buf: integer, manifest_type: string, packages: table<string, any>, is_initial?: boolean)
---@field display_loading_for_package fun(buf: integer, manifest_type: string, package_info: NewPackage, mode?: "loading"|"working")
---@field update_package fun(buf: integer, package_data: PackageResult)
---@field has_virtual_text fun(buf: integer): boolean
---@field show fun(buf: integer, manifest_type: string, packages?: table<string, any>)
---@field hide fun(buf: integer)
---@field toggle fun(buf: integer, manifest_type: string, packages?: table<string, any>)
---@field setup_state_handlers fun(handlers: VirtualTextHandlers)
---@field find_package_in_line? fun(line: string): string|nil  Optional per-manager line parser

-- ============================================================================
-- Hub declared types
-- ============================================================================

---@class DeclaredModule
---@field get_data fun(): table<string, any>

---@class DeclaredHub
---@field get_data fun(manager_type: string, opts?: { force_refresh?: boolean }): table
---@field clear_cache fun(manager_type?: string, package_name?: string)
---@field refresh_data fun(manager_type: string): table

-- ============================================================================
-- Hub installed types
-- ============================================================================

---@class InstalledModule
---@field get_package_installed fun(package_name: string, callback: fun(err: string|nil, version: string|nil))

---@class InstalledPackageInfo
---@field version string|nil The installed version
---@field metadata? table<string, any> Additional metadata

---@class InstalledHub
---@field get_package_installed fun(manager_type: string, package_name: string, callback: fun(err: string|nil, version: string|nil))
---@field get_data fun(manager_type: string): table<string, string|nil>
---@field get_full_data fun(manager_type: string): table<string, InstalledPackageInfo>
---@field clear_cache fun(manager_type?: string, package_name?: string)

-- ============================================================================
-- Hub latest types
-- ============================================================================

---@class LatestPackageInfo
---@field version string|nil The latest available version
---@field metadata table<string, any> Additional metadata

---@class LatestModule
---@field get_package_latest fun(package_name: string, callback: fun(err: string|nil, version: string|nil, metadata: table|nil))

---@class LatestHub
---@field get_package_latest fun(manager_type: string, package_name: string, callback: fun(err: string|nil, info: LatestPackageInfo|nil))
---@field get_data fun(manager_type: string): table<string, LatestPackageInfo>
---@field clear_cache fun(manager_type?: string, package_name?: string)

---@class DependencyFormatContext
---@field buf integer Buffer number
---@field package string Package name
---@field manifest_type string Manager type

-- ============================================================================
-- Installer types
-- ============================================================================

--- Result returned by all installer operations
---@class InstallerResult
---@field success boolean Whether the operation succeeded
---@field message? string User-friendly message about the operation result
---@field data? any Additional data returned by the installer
---@field packages? string[] List of packages affected by the operation
---@field no_retry? boolean When true, the operator will not retry or re-show the version picker after failure

--- Unified callback convention for all installer operations
---@alias InstallerCallback fun(result: InstallerResult)

--- Installer module interface that each manager must implement.
--- All callbacks use the single-argument convention: callback(result)
---@class InstallerModule
---@field install fun(manager_type: string, packages: string[], callback: InstallerCallback)
---@field update fun(manager_type: string, packages: string[], callback: InstallerCallback)
---@field delete fun(manager_type: string, packages: string[], callback: InstallerCallback)
---@field check_outdated fun(manager_type: string, callback: InstallerCallback)
---@field update_direct fun(manager_type: string, package: string, version: string, callback: InstallerCallback)

---@class VersionSelectionContext
---@field section? string The dependency section (e.g., "dependencies", "dev-dependencies")

-- ============================================================================
-- State module types
-- ============================================================================

---@class StateModule
---@field _state {buffers: table<integer, StateBufferData>, _event_handlers: table<string, function[]>}
---@field _handlers VirtualTextHandlers
---@field handle_buffer_event fun(buf: integer, event_type: string, data?: any): BufferEventData|nil
---@field clear_pending_state fun(bufnr: integer)
---@field handle_buffer_change fun(bufnr: integer)
---@field set_handlers fun(handlers: VirtualTextHandlers)
---@field setup fun()
---@field on fun(event: string, handler: fun(buf: integer, event_data: BufferEventData, buffer_state: StateBufferData))
---@field get_buffer_state fun(buf: integer): StateBufferData

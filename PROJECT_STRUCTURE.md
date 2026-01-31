# Предложена структура на проекта (lvim-dependencies)

Това е логична, модулна структура, която покрива трите manifest типа (package.json, Cargo.toml, pubspec.yaml) и разделя отговорностите на парсъри, UI, actions (checkers), utils и libs.

Препоръчана директория: `lua/lvim-dependencies/`

Дървото (основно в `lua/lvim-dependencies/`):

```text
lvim-dependencies/
├── lua/
│   └── lvim-dependencies/
│       ├── init.lua                     -- setup/entry: setup config + autocommands
│       ├── config.lua                   -- конфигурация (enable/disable per manifest, options)
│       ├── state.lua                    -- централен state (buffers, dependencies, namespace, helpers)
│       ├── autocommands.lua             -- регистрация на autocmds (BufEnter, BufWritePost, ...)
│       ├── commands.lua                 -- user commands (e.g. LDepsUpdate, LDepsToggle)
│       ├── utils/
│       │   ├── init.lua                 -- експортира helpers (merge, file_exists, clean_version, ...)
│       │   ├── fs.lua                   -- file helpers (read_file, find_file_upwards)
│       │   └── clean_version.lua        -- (ако предпочиташ отделен файл)
│       ├── libs/
│       │   ├── json_parser.lua          -- rxi/json.lua (vendored) или `vim.json` wrapper
│       │   └── toml.lua                 -- optional: pure-lua toml (vendored) OR omit if using regex
│       ├── parsers/
│       │   ├── package.lua              -- парсър за package.json (парсва installed, invalid)
│       │   ├── cargo.lua                -- парсър за Cargo.toml (simple TOML or regex)
│       │   └── pubspec.lua              -- парсър за pubspec.yaml (simple YAML or regex)
│       ├── actions/
│       │   ├── check_outdated.lua       -- JS (npm/pnpm/yarn/bun) checker (jobstart -> state.outdated)
│       │   ├── check_crates_outdated.lua-- Rust checker (cargo-outdated or crates.io fallback)
│       │   └── check_pub_outdated.lua   -- Dart checker (dart pub outdated or pub.dev fallback)
│       ├── ui/
│       │   ├── virtual_text.lua         -- показване на extmarks (reads state)
│       │   └── floating.lua              -- детайлна информация в floating window
│       └── tests/                       -- unit тестове (optional)
├── doc/                                -- документация (helpfiles, README snippets)
└── README.md
```

Кой файл какво прави (кратко)

- init.lua
    - Инициализира конфиг, създава namespace (`state.namespace.create()`), регистрира commands и autocmds чрез `autocommands.lua`.
    - Точка за require от потребителския `init.lua` (plugin setup).

- config.lua
    - Таблица с опции по manifest: enable/disable, icons, highlights, debounce, checkers enabled и т.н.
    - Пример keys: `config.package.enabled`, `config.crates.enabled`, `config.pubspec.enabled`, `config.checkers.cargo.use_cli`, ...

- state.lua
    - Централен state: `buffers`, `dependencies` (per-manifest), `namespace`, `last_run` и helper функции (save_buffer, set_installed, set_outdated, clear_virtual_text и т.н.).
    - Всички модули четат/пишат в state.

- autocommands.lua
    - Регистрира autocmds за `BufEnter`, `BufWritePost`, `TextChanged`, `BufDelete`.
    - Дебаунс логика за parse + checkers; извиква parser.parse_buffer(bufnr) и след това actions.check_outdated / check_crates_outdated / check_pub_outdated.

- parsers/\*
    - Всеки парсър има функция `parse_buffer(bufnr)` (и/или `attach(bufnr)`), която:
        - прочита буфера,
        - парсва -> попълва `state.set_installed(manifest_key, ...)` и `state.set_invalid(...)`,
        - записва buffer meta (state.save_buffer),
        - не задължава да прави check за latest версии (actions правят това).
    - Ако предпочиташ: `parsers/package.lua` използва vendored json_parser; `parsers/cargo.lua` може да използва pure-lua toml или regex; `parsers/pubspec.lua` използва прост YAML regex или `yq`/yaml lib.

- actions/\*
    - Checkers за latest версии:
        - `check_outdated.lua` за JS: използва `npm outdated --json`, `pnpm outdated --json`, `bun outdated --json`, `yarn outdated --json` (special handling).
        - `check_crates_outdated.lua` за Rust: първо проверка дали `cargo-outdated` е наличен; ако е - `cargo outdated --format=json` и парсване, иначе fallback към crates.io API per crate.
        - `check_pub_outdated.lua` за Dart: `dart pub outdated --json` ако има, иначе fallback към pub.dev (REST или парсване).
    - Записват `state.set_outdated(manifest_key, table)` и извикват `virtual_text.display(bufnr, manifest_key)`.

- ui/virtual_text.lua
    - Чете `state.get_buffer(bufnr).lines` и `state.get_dependencies(manifest_key)`.
    - За всеки ред решава дали е dependency declaration (helper get_dependency_name_from_line) и слага extmark с подходящ текст:
        - ако `state.dependencies.outdated[name]` съществува -> показва latest
        - ако invalid -> показва diagnostic
        - иначе показва current (или hides if config.hide_up_to_date).

- libs/
    - Vendорни библиотеки (rxi json.lua, optional pure-lua toml, optional yaml). Ако не искаш външни бинарни зависимости, предпочитай pure-lua libs или regex.

- utils/
    - Общи помощници: `clean_version`, `merge`, `file_exists`, `read_file`, `find_file_upwards`, `notify`, `get_cursor_position`, и т.н.

Изисквания и добри практики

- All modules use centralized state: require("lvim-dependencies.state").
- Парсерите попълват само installed/invalid; checker-ите попълват outdated.
- Дебаунс при TextChanged/BufWritePost (200–500ms) за по-малко jobstart.
- Използвай `vim.fn.jobstart` / `vim.loop` асинхронно и не блокирай UI.
- Кеширай резултатите (state.last_run или per-buffer last_run) за да не правиш check често (напр. 1 час).
- Предостави конфиг за разрешаване/изключване на checkers (особено cargo/pub), и опция "cli-first" vs "registry-first".
- За vendoring на парсъри: предпочитай pure-Lua toml/yaml ако искаш zero-native-deps. Ако използваш LebJe/toml.lua, ще трябва да компилираш (не е pure-Lua).

Примери на require пътища

- parser: `local package_parser = require("lvim-dependencies.parsers.package")`
- checker: `local checker = require("lvim-dependencies.actions.check_outdated")`
- utils: `local utils = require("lvim-dependencies.utils")` (или `require("lvim-dependencies.utils.clean_version")` ако разделен)
- state: `local state = require("lvim-dependencies.state")`
- ui: `local virtual_text = require("lvim-dependencies.ui.virtual_text")`

Бърз пример на flow при open/save на manifest:

1. autocmd -> schedule parse (debounced)
2. parser.parse_buffer(bufnr) -> state.set_installed / set_invalid
3. actions.check\_\*\_outdated(bufnr, manifest_key) asynchronously -> state.set_outdated(...)
4. virtual_text.display(bufnr, manifest_key) -> четене от state, поставяне на extmarks

Ако искаш, мога да:

- генерирам skeleton файлове (празни модули) за всяка от горните позиции; или
- напиша конкретен `actions/check_crates_outdated.lua` и `actions/check_pub_outdated.lua` (CLI-first); или
- предложа конкретни config defaults за config.lua.

Кое предпочиташ като следваща стъпка?

- INSERT

- UPDATE

- DELETE

DELETE (title)
Manifest: pubspec Scope: dependencies (subtitle)

-тук искам да имам въпрос за действие - например - Променете версията на 'confirm_dialog@^1.0.4' - или- Изтрийте пакет

- пакет 1
- пакет 2
- пакет 3

Press y / <CR> to confirm, n / <Esc> to cancel (navigation)

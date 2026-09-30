# AiLimitWidget — «Лимиты ИИ»

Сколько осталось лимитов у Claude Code, Antigravity, Codex и других ИИ — прямо в строке меню macOS или у часов на панели задач Windows.
Две строки: сверху сессия (5 ч), снизу неделя.

- **macOS** — нативный виджет для строки меню на Swift (AppKit + SwiftUI), macOS 12 и новее. Значка в Dock нет.
- **Windows** — C# (WPF), Windows 10 / 11. Собирается компилятором из .NET Framework 4, который уже есть в Windows, — ничего ставить не нужно.

## Скачать

| ОС | Файл | Примечание |
|---|---|---|
| macOS | [AiLimitWidget.dmg](release/AiLimitWidget.dmg) | Apple Silicon и Intel, macOS 12+ |
| Windows | [AiLimitWidget.exe](release/AiLimitWidget.exe) | один файл, установка не нужна |

Приложения не подписаны, поэтому при первом запуске система может предупредить:

- **macOS** — откройте DMG и перетащите приложение на ярлык «Программы» рядом, затем правый клик → «Открыть» или один раз выполните
  `xattr -dr com.apple.quarantine /Applications/AiLimitWidget.app`.
- **Windows** — в окне SmartScreen нажмите «Подробнее» → «Выполнить в любом случае».

## Возможности

- Наведение — быстрый просмотр; нажатие — панель с полосами, временем сброса и подробностями; нажали мимо или Esc — панель закрывается; правый клик или ⋯ — меню.
- В полноэкранной программе быстрый просмотр по наведению не всплывает.
- У каждого ИИ свой цвет. Другие ИИ появляются сами, как только на компьютере есть вход в них; скрыть лишние: ⋯ → «Показывать».

### Откуда берутся данные

Виджет только читает уже сохранённые входы — сам ничего не вводит и данные никуда, кроме серверов самих сервисов, не отправляет.

| Сервис | macOS | Windows |
|---|---|---|
| Claude Code | связка ключей (`Claude Code-credentials`), иначе `~/.claude/.credentials.json` | `%USERPROFILE%\.claude\.credentials.json` |
| Antigravity (Gemini, Claude, GPT) | `agy -p /quota --output-format json` — квота не тратится; `agy` ищется в PATH из `~/.zshrc` | то же |
| Codex | `~/.codex/auth.json` | `%USERPROFILE%\.codex\auth.json` |
| Gemini CLI | `~/.gemini/oauth_creds.json` (вход через Google); суточные лимиты Pro и Flash | `%USERPROFILE%\.gemini\oauth_creds.json` |
| GitHub Copilot | Copilot CLI (связка ключей `copilot-cli` или `~/.copilot`), плагин Copilot (`~/.config/github-copilot`) или `gh auth token`; месячные лимиты | Copilot CLI (диспетчер учётных данных или `%USERPROFILE%\.copilot`), плагин Copilot (`%LOCALAPPDATA%\github-copilot`) или `gh auth token` |
| Cursor | `~/Library/Application Support/Cursor/…/state.vscdb`; расход за месяц подписки | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` (читается без sqlite3) |

Выход из Antigravity на Mac открывает Терминал с `agy -i /logout` (macOS может спросить разрешение управлять Терминалом).

Настройки хранятся в `~/Library/Application Support/AiLimitWidget/` (macOS) и `%APPDATA%\AiLimitWidget\` (Windows).

## Структура

```
macos/     исходники Swift (Sources/, Shared/, Resources/) и build.sh
windows/   исходник AiLimitWidget.cs, значок и build.cmd
release/   готовые AiLimitWidget.dmg и AiLimitWidget.exe
```

## Сборка

### macOS

```bash
xcode-select --install          # один раз, если нет Xcode или Command Line Tools
bash macos/build.sh             # универсальная сборка: Apple Silicon + Intel
ARCHS=arm64 bash macos/build.sh # только Apple Silicon
```

Результат — `macos/build/AiLimitWidget.app` и `release/AiLimitWidget.dmg`.

### Windows

```bat
windows\build.cmd
```

Результат — `release\AiLimitWidget.exe`. Если виджет запущен из `release\`, сначала закройте его, иначе файл занят.

После изменений в коде пересоберите нужную версию и закоммитьте обновлённый файл из `release/` вместе с исходниками.

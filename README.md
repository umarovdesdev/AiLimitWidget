# AiLimitWidget — «Лимиты ИИ»

Нативный виджет для строки меню macOS на Swift (AppKit + SwiftUI), macOS 12 и новее. Значка в Dock нет.

## Сборка

```bash
xcode-select --install      # один раз, если нет Xcode
bash build.sh               # только Apple Silicon: ARCHS=arm64 bash build.sh
```

Готовый `build/AiLimitWidget.app` перенесите в «Программы».
Если .app скопировали с другого Mac (zip, флешка), macOS может заблокировать запуск — один раз:
`xattr -dr com.apple.quarantine /Applications/AiLimitWidget.app` (или правый клик → «Открыть»).

## Возможности


Проценты Claude Code, Antigravity (Gemini, Claude и GPT), Codex и других ИИ — прямо в строке меню, двумя строками
(сверху сессия 5 ч, снизу неделя), как надпись у часов на Windows. Наведение — быстрый просмотр,
нажатие — панель с полосами, временем сброса и подробностями; нажали мимо или Esc — панель закрывается; правый клик или ⋯ — меню.
В полноэкранной программе быстрый просмотр по наведению не всплывает.

Другие ИИ появляются сами, как только на этом Mac есть вход в них, у каждого свой цвет:
Gemini CLI — голубой, GitHub Copilot — фиолетовый, Cursor — бирюзовый. Скрыть: ⋯ → Показывать.

Откуда данные на Mac:
- **Claude Code** — вход из связки ключей (`Claude Code-credentials`), иначе `~/.claude/.credentials.json`; только чтение.
- **Antigravity** — `agy -p /quota --output-format json` (квота не тратится); `agy` ищется в PATH из `~/.zshrc`.
- **Codex** — `~/.codex/auth.json`.
- **Gemini CLI** — `~/.gemini/oauth_creds.json` (вход через Google); лимиты запросов на сутки для Pro и Flash.
- **GitHub Copilot** — вход Copilot CLI (связка ключей `copilot-cli` или `~/.copilot`), плагина Copilot (`~/.config/github-copilot`) или `gh auth token`; месячные лимиты.
- **Cursor** — вход из `~/Library/Application Support/Cursor/…/state.vscdb`; расход за месяц подписки.

Настройки: `~/Library/Application Support/AiLimitWidget/`.

Выход из Antigravity открывает Терминал с `agy -i /logout` (macOS может спросить разрешение управлять Терминалом).

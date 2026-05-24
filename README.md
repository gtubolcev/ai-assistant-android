# AI Assistant

Офлайн-первый AI-помощник для Android на базе **LFM2.5-1.2B** (Cactus SDK).

## Возможности

- 💬 Чат с on-device LLM (LFM2.5-1.2B Q4, ~720 MB RAM)
- 🔧 Tool calling: web_fetch, CalDAV (события и задачи VTODO)
- 📡 Работает полностью офлайн
- 🔒 Данные не покидают устройство

## Стек

| Компонент | Технология |
|---|---|
| Inference | [Cactus SDK](https://github.com/cactus-compute/cactus) |
| Модель | LFM2.5-1.2B-Instruct GGUF Q4_0 |
| MCP | [mcp_dart](https://pub.dev/packages/mcp_dart) (StreamableHTTP) |
| UI | Flutter + Material 3 |
| Календарь | CalDAV (Nextcloud / Radicale / Baikal) |

## Сборка

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

APK будет в `build/app/outputs/flutter-apk/`.

## Настройка CalDAV

В приложении → ⚙️ → укажи:
- Адрес сервера: `https://nextcloud.example.com/remote.php/dav`
- Логин / пароль
- Путь к календарю: `/calendars/username/personal/`

## Требования

- Android API 26+ (Android 8.0)
- ARM64 или ARMv7
- 2+ GB свободной RAM

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/chat_provider.dart';

// ── Curated model list ─────────────────────────────────────────────────────────

class _ModelEntry {
  final String name;
  final String description;
  final int sizeMb;
  final String filename;
  final String url;
  const _ModelEntry({
    required this.name,
    required this.description,
    required this.sizeMb,
    required this.filename,
    required this.url,
  });
}

const _kCuratedModels = [
  _ModelEntry(
    name: 'LFM2.5 1.2B · Function Calling (рекомендуется)',
    description: 'Специально дообучена для вызова инструментов (tool calling). '
        'Формат ChatML. 731 МБ.',
    sizeMb: 731,
    filename: 'LFM2.5-1.2B-Nova-Function-Calling.Q4_K_M.gguf',
    url: 'https://huggingface.co/NovachronoAI/LFM2.5-1.2B-Nova-Function-Calling-GGUF'
        '/resolve/main/LFM2.5-1.2B-Nova-Function-Calling.Q4_K_M.gguf',
  ),
  _ModelEntry(
    name: 'LFM2.5 1.2B · Function Calling (компакт Q3)',
    description: 'То же, но квантизация Q3_K_M — меньше памяти, чуть ниже качество. '
        '600 МБ.',
    sizeMb: 600,
    filename: 'LFM2.5-1.2B-Nova-Function-Calling.Q3_K_M.gguf',
    url: 'https://huggingface.co/NovachronoAI/LFM2.5-1.2B-Nova-Function-Calling-GGUF'
        '/resolve/main/LFM2.5-1.2B-Nova-Function-Calling.Q3_K_M.gguf',
  ),
  _ModelEntry(
    name: 'Qwen 2.5 1.5B Instruct Q4_K_M',
    description: 'Отличный JSON tool calling, стабильный. Чуть больше — 1.1 ГБ.',
    sizeMb: 1120,
    filename: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF'
        '/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
  ),
];

/// Keys that are saved/restored in settings backup.
const _kBackupKeys = [
  'mcp_url',
  'mcp_user',
  'mcp_password',
  'mcp_token',
  'caldav_url',
  'caldav_user',
  'caldav_password',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // MCP fields
  final _urlCtrl = TextEditingController();
  final _mcpUserCtrl = TextEditingController();
  final _mcpPassCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _obscureMcpPass = true;
  bool _obscureToken = true;
  bool _savingMcp = false;

  // CalDAV fields
  final _caldavUrlCtrl = TextEditingController();
  final _caldavUserCtrl = TextEditingController();
  final _caldavPassCtrl = TextEditingController();
  bool _obscureCaldavPass = true;
  bool _savingCaldav = false;

  // Model fields
  bool _pickingModel = false;

  // Backup fields
  bool _exporting = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('mcp_url') ?? '';
      _mcpUserCtrl.text = prefs.getString('mcp_user') ?? '';
      _mcpPassCtrl.text = prefs.getString('mcp_password') ?? '';
      _tokenCtrl.text = prefs.getString('mcp_token') ?? '';
      _caldavUrlCtrl.text = prefs.getString('caldav_url') ?? '';
      _caldavUserCtrl.text = prefs.getString('caldav_user') ?? '';
      _caldavPassCtrl.text = prefs.getString('caldav_password') ?? '';
    });
  }

  // ── CalDAV save ────────────────────────────────────────────────────────────

  Future<void> _saveCaldav() async {
    setState(() => _savingCaldav = true);
    await context.read<ChatProvider>().saveCaldavConfig(
          url: _caldavUrlCtrl.text.trim(),
          user: _caldavUserCtrl.text.trim(),
          password: _caldavPassCtrl.text,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('💾 CalDAV настройки сохранены. Перезапустите приложение.'),
        ),
      );
      setState(() => _savingCaldav = false);
    }
  }

  // ── MCP save ───────────────────────────────────────────────────────────────

  Future<void> _saveMcp() async {
    setState(() => _savingMcp = true);
    await context.read<ChatProvider>().saveMcpConfig(
          url: _urlCtrl.text.trim(),
          user: _mcpUserCtrl.text.trim(),
          password: _mcpPassCtrl.text,
          token: _tokenCtrl.text.trim(),
        );
    if (mounted) {
      final connected = context.read<ChatProvider>().isMcpConnected;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(connected
              ? '✅ Подключено к MCP серверу'
              : '⚠️ Не удалось подключиться к MCP'),
        ),
      );
      setState(() => _savingMcp = false);
    }
  }

  // ── Model download (bottom sheet) ──────────────────────────────────────────

  void _showModelPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ModelPickerSheet(
        onDownload: (entry) {
          Navigator.pop(context);
          context.read<ChatProvider>().downloadModelFromUrl(
                entry.url,
                entry.filename,
              );
        },
      ),
    );
  }

  // ── Model file picker ──────────────────────────────────────────────────────

  Future<void> _pickModel() async {
    // Use FileType.any — Android doesn't know .gguf MIME type, so
    // FileType.custom with allowedExtensions silently shows nothing.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowCompression: false,
    );

    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    if (!path.toLowerCase().endsWith('.gguf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ Выберите файл с расширением .gguf')),
      );
      return;
    }

    setState(() => _pickingModel = true);

    await context.read<ChatProvider>().importModelFromFile(path);

    if (mounted) {
      final provider = context.read<ChatProvider>();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.isModelReady
              ? '✅ Модель загружена: ${provider.activeModelName}'
              : '⚠️ ${provider.errorText ?? 'Не удалось загрузить модель'}'),
        ),
      );
      setState(() => _pickingModel = false);
    }
  }

  // ── Settings backup / restore ──────────────────────────────────────────────

  Future<void> _exportSettings() async {
    setState(() => _exporting = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, String>{};
      for (final key in _kBackupKeys) {
        final v = prefs.getString(key);
        if (v != null) data[key] = v;
      }
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final bytes = utf8.encode(json);

      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить бэкап настроек',
        fileName: 'ai_assistant_backup.json',
        bytes: Uint8List.fromList(bytes),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(savedPath != null
                ? '✅ Бэкап сохранён'
                : 'Сохранение отменено'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠️ Ошибка экспорта: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Looks for ai_assistant_backup.json in common Downloads locations.
  static File? _findBackupInDownloads() {
    const candidates = [
      '/storage/emulated/0/Download/ai_assistant_backup.json',
      '/storage/emulated/0/Downloads/ai_assistant_backup.json',
    ];
    for (final path in candidates) {
      try {
        final f = File(path);
        if (f.existsSync()) return f;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _importSettings() async {
    setState(() => _importing = true);
    try {
      Uint8List? bytes;

      // ── Auto-detect: try reading backup directly from Downloads ──────────────
      // Works on Android ≤12 with READ_EXTERNAL_STORAGE.
      // On Android 13+ (scoped storage) readAsBytesSync throws — we fall
      // through silently to the file picker without bothering the user.
      final found = _findBackupInDownloads();
      if (found != null) {
        try {
          final data = found.readAsBytesSync();
          // Read succeeded — ask for confirmation before applying.
          if (mounted) {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Найден бэкап'),
                content: Text('Восстановить настройки из\n${found.path}?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Восстановить'),
                  ),
                ],
              ),
            );
            if (confirmed == null || confirmed == false) {
              setState(() => _importing = false);
              return;
            }
            bytes = data;
          }
        } catch (_) {
          // Scoped storage (Android 13+): direct read denied — use file picker.
        }
      }

      // ── File picker ──────────────────────────────────────────────────────────
      if (bytes == null) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json'],
          withData: true,
        );
        bytes = result?.files.single.bytes;
      }

      if (bytes == null || !mounted) {
        setState(() => _importing = false);
        return;
      }

      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final prefs = await SharedPreferences.getInstance();
      for (final key in _kBackupKeys) {
        if (data.containsKey(key)) {
          await prefs.setString(key, data[key] as String);
        }
      }

      await _loadSaved();

      if (mounted) {
        await context.read<ChatProvider>().saveMcpConfig(
              url: prefs.getString('mcp_url') ?? '',
              user: prefs.getString('mcp_user') ?? '',
              password: prefs.getString('mcp_password') ?? '',
              token: prefs.getString('mcp_token') ?? '',
            );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Настройки восстановлены и применены')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠️ Ошибка импорта: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _mcpUserCtrl.dispose();
    _mcpPassCtrl.dispose();
    _tokenCtrl.dispose();
    _caldavUrlCtrl.dispose();
    _caldavUserCtrl.dispose();
    _caldavPassCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ── Backup section ─────────────────────────────────────────────────
          const _SectionHeader('Бэкап настроек'),
          const SizedBox(height: 4),
          const Text(
            'Сохраните все настройки MCP и CalDAV в файл, '
            'чтобы восстановить их после переустановки.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_exporting || _importing) ? null : _exportSettings,
                  icon: _exporting
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.upload_outlined),
                  label: const Text('Экспорт'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_exporting || _importing) ? null : _importSettings,
                  icon: _importing
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_outlined),
                  label: const Text('Импорт'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),

          // ── Model section ──────────────────────────────────────────────────
          const _SectionHeader('Модель'),
          const SizedBox(height: 4),
          const Text(
            'Скачайте готовую модель из интернета или выберите '
            'свой .gguf файл с устройства.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),

          // Status + progress
          Consumer<ChatProvider>(
            builder: (_, provider, __) {
              final downloading = provider.downloadProgress != null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StatusRow(
                    ok: provider.isModelReady,
                    text: provider.isModelReady
                        ? 'Активна: ${provider.activeModelName}'
                        : provider.statusText,
                  ),
                  if (downloading) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: provider.downloadProgress,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          provider.statusText,
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 24),
                            foregroundColor: Colors.red,
                          ),
                          onPressed: provider.cancelDownload,
                          child: const Text('Отмена', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  ],
                  if (provider.activeModelPath.isNotEmpty && !downloading) ...[
                    const SizedBox(height: 8),
                    _HintCard(
                      icon: Icons.insert_drive_file_outlined,
                      text: 'Файл: ${provider.activeModelName}',
                    ),
                  ],
                ],
              );
            },
          ),

          const SizedBox(height: 12),

          // Buttons: download or pick local
          Consumer<ChatProvider>(
            builder: (_, provider, __) {
              final busy = _pickingModel || provider.downloadProgress != null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : _showModelPicker,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Скачать модель из интернета'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: busy ? null : _pickModel,
                    icon: _pickingModel
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open_outlined),
                    label: const Text('Выбрать файл .gguf'),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 32),

          // ── MCP section ────────────────────────────────────────────────────
          const _SectionHeader('MCP сервер'),
          const SizedBox(height: 4),
          const Text(
            'Адрес dav-mcp сервера, который предоставляет инструменты '
            'для работы с календарём, контактами и задачами (CalDAV/CardDAV).',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _Field(
            controller: _urlCtrl,
            label: 'URL MCP сервера',
            hint: 'https://mcp2.rakulka.ru/mcp',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          _HintCard(
            icon: Icons.info_outline,
            text: 'Basic Auth (nextcloud-mcp): заполни логин и пароль.\n'
                'Bearer Token (dav-mcp): оставь логин пустым, заполни токен.',
          ),
          const SizedBox(height: 12),
          _Field(
            controller: _mcpUserCtrl,
            label: 'Логин (Basic Auth)',
            hint: 'gtubolcev',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _mcpPassCtrl,
            obscureText: _obscureMcpPass,
            decoration: InputDecoration(
              labelText: 'Пароль (Basic Auth)',
              hintText: 'App password из Nextcloud',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscureMcpPass
                    ? Icons.visibility
                    : Icons.visibility_off),
                onPressed: () =>
                    setState(() => _obscureMcpPass = !_obscureMcpPass),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtrl,
            obscureText: _obscureToken,
            decoration: InputDecoration(
              labelText: 'Bearer Token (опционально)',
              hintText: 'Только для серверов с Bearer Auth',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscureToken
                    ? Icons.visibility
                    : Icons.visibility_off),
                onPressed: () =>
                    setState(() => _obscureToken = !_obscureToken),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Consumer<ChatProvider>(
            builder: (_, provider, __) => _StatusRow(
              ok: provider.isMcpConnected,
              text: provider.statusText,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _savingMcp ? null : _saveMcp,
            icon: _savingMcp
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_done_outlined),
            label: const Text('Сохранить и подключить'),
          ),

          const SizedBox(height: 32),

          // ── CalDAV section ─────────────────────────────────────────────────
          const _SectionHeader('CalDAV сервер'),
          const SizedBox(height: 4),
          const Text(
            'Данные для подключения к вашему CalDAV/CardDAV серверу. '
            'Передаются модели в системный промпт, чтобы она знала '
            'правильный URL при создании/изменении событий и задач.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _Field(
            controller: _caldavUrlCtrl,
            label: 'CalDAV URL',
            hint: 'https://nextcloud.example.com/remote.php/dav',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          _Field(
            controller: _caldavUserCtrl,
            label: 'Имя пользователя',
            hint: 'username',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _caldavPassCtrl,
            obscureText: _obscureCaldavPass,
            decoration: InputDecoration(
              labelText: 'Пароль',
              hintText: 'Пароль CalDAV',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscureCaldavPass
                    ? Icons.visibility
                    : Icons.visibility_off),
                onPressed: () =>
                    setState(() => _obscureCaldavPass = !_obscureCaldavPass),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _savingCaldav ? null : _saveCaldav,
            icon: _savingCaldav
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_outlined),
            label: const Text('Сохранить CalDAV'),
          ),

          const SizedBox(height: 32),

          // ── About ───────────────────────────────────────────────────────────
          const _SectionHeader('О приложении'),
          const SizedBox(height: 8),
          Consumer<ChatProvider>(
            builder: (_, p, __) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('AI Assistant'),
              subtitle: Text(
                'Офлайн-ассистент · llama_cpp_dart + MCP\n'
                'Модель: ${p.activeModelName.isEmpty ? "(не выбрана)" : p.activeModelName}',
              ),
              isThreeLine: true,
            ),
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.lock_outline),
            title: Text('Приватность'),
            subtitle: Text(
                'LLM работает полностью на устройстве.\n'
                'Данные календаря хранятся на твоём сервере.'),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final bool ok;
  final String text;
  const _StatusRow({required this.ok, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          ok ? Icons.circle : Icons.circle_outlined,
          size: 12,
          color: ok ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: ok ? Colors.green : Colors.grey,
            ),
          ),
        ),
      ],
    );
  }
}

class _HintCard extends StatelessWidget {
  final IconData icon;
  final String text;
  const _HintCard({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Model picker bottom sheet ──────────────────────────────────────────────────

class _ModelPickerSheet extends StatelessWidget {
  final void Function(_ModelEntry entry) onDownload;
  const _ModelPickerSheet({required this.onDownload});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          // handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Выберите модель',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              itemCount: _kCuratedModels.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final m = _kCuratedModels[i];
                return Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          m.description,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => onDownload(m),
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: Text('Скачать (${m.sizeMb >= 1000 ? '${(m.sizeMb / 1024).toStringAsFixed(1)} ГБ' : '${m.sizeMb} МБ'})'),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;

  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

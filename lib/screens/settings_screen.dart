import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/chat_provider.dart';

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
  String _modelFileName = '';

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
    final savedPath = prefs.getString('model_source_path') ?? '';
    setState(() {
      _urlCtrl.text = prefs.getString('mcp_url') ?? '';
      _mcpUserCtrl.text = prefs.getString('mcp_user') ?? '';
      _mcpPassCtrl.text = prefs.getString('mcp_password') ?? '';
      _tokenCtrl.text = prefs.getString('mcp_token') ?? '';
      _caldavUrlCtrl.text = prefs.getString('caldav_url') ?? '';
      _caldavUserCtrl.text = prefs.getString('caldav_user') ?? '';
      _caldavPassCtrl.text = prefs.getString('caldav_password') ?? '';
      if (savedPath.isNotEmpty) {
        _modelFileName = savedPath.split('/').last;
      }
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

    setState(() {
      _pickingModel = true;
      _modelFileName = path.split('/').last;
    });

    await context.read<ChatProvider>().importModelFromFile(path);

    if (mounted) {
      final provider = context.read<ChatProvider>();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.isModelReady
              ? '✅ Модель загружена: $_modelFileName'
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

  Future<void> _importSettings() async {
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );

      final bytes = result?.files.single.bytes;
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
        // Reconnect MCP with restored credentials.
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
            'Скачайте одну из готовых моделей или выберите '
            'свой .gguf файл с устройства.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Consumer<ChatProvider>(
            builder: (_, provider, __) => _StatusRow(
              ok: provider.isModelReady,
              text: provider.isModelReady
                  ? 'Активна: ${provider.activeModelSlug}'
                  : provider.statusText,
            ),
          ),
          const SizedBox(height: 12),
          // List of available Cactus models
          Consumer<ChatProvider>(
            builder: (_, provider, __) => Column(
              children: kAvailableCactusModels.map((m) {
                final isActive = provider.isModelReady &&
                    provider.activeModelSlug == m.slug;
                return _ModelCard(
                  model: m,
                  isActive: isActive,
                  isLoading: !provider.isModelReady && provider.statusText.contains('Загр') ||
                      (!provider.isModelReady && provider.statusText.contains('Инициализ') &&
                          provider.activeModelSlug == m.slug),
                  onDownload: () =>
                      context.read<ChatProvider>().downloadAndLoadModel(m.slug),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          const Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('или свой файл',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 12),
          if (_modelFileName.isNotEmpty) ...[
            _HintCard(
              icon: Icons.insert_drive_file_outlined,
              text: 'Файл: $_modelFileName',
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            onPressed: _pickingModel ? null : _pickModel,
            icon: _pickingModel
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open_outlined),
            label: const Text('Выбрать файл .gguf'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Только модели, совместимые с llama.cpp. '
            'LFM2.5-Instruct не поддерживается Cactus SDK.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
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
                'Офлайн-ассистент · Cactus SDK + MCP\n'
                'Модель: ${p.activeModelSlug}',
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

class _ModelCard extends StatelessWidget {
  final CactusModelInfo model;
  final bool isActive;
  final bool isLoading;
  final VoidCallback onDownload;

  const _ModelCard({
    required this.model,
    required this.isActive,
    required this.isLoading,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sizeTxt = model.sizeMb >= 1000
        ? '${(model.sizeMb / 1000).toStringAsFixed(1)} ГБ'
        : '${model.sizeMb} МБ';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isActive
          ? scheme.primaryContainer.withOpacity(0.4)
          : scheme.surfaceContainerHighest.withOpacity(0.5),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isActive
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        model.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: isActive ? scheme.primary : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          sizeTxt,
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    model.description,
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isActive)
              Icon(Icons.check_circle_rounded,
                  color: scheme.primary, size: 20)
            else if (isLoading)
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              TextButton(
                onPressed: onDownload,
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Скачать'),
              ),
          ],
        ),
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

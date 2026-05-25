import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/chat_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // MCP fields
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _obscureToken = true;
  bool _savingMcp = false;

  // Model fields
  final _modelPathCtrl = TextEditingController();
  bool _savingModel = false;
  String _extHintPath = '';

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _loadHintPath();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('mcp_url') ?? '';
      _tokenCtrl.text = prefs.getString('mcp_token') ?? '';
      _modelPathCtrl.text = prefs.getString('model_path') ?? '';
    });
  }

  Future<void> _loadHintPath() async {
    final path =
        await context.read<ChatProvider>().externalModelHintPath();
    if (mounted) setState(() => _extHintPath = path);
  }

  // ── MCP save ───────────────────────────────────────────────────────────────

  Future<void> _saveMcp() async {
    setState(() => _savingMcp = true);
    await context.read<ChatProvider>().saveMcpConfig(
          url: _urlCtrl.text.trim(),
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

  // ── Model path save ────────────────────────────────────────────────────────

  Future<void> _saveModelPath() async {
    setState(() => _savingModel = true);
    await context.read<ChatProvider>().saveModelPath(_modelPathCtrl.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('💾 Путь сохранён. Перезапустите приложение для применения.'),
        ),
      );
      setState(() => _savingModel = false);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _modelPathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ── Model section ──────────────────────────────────────────────────
          const _SectionHeader('Модель'),
          const SizedBox(height: 4),
          const Text(
            'Путь к файлу модели (.gguf) или папке с моделью. '
            'Оставьте пустым для автоматического поиска и загрузки.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelPathCtrl,
            decoration: const InputDecoration(
              labelText: 'Путь к модели (необязательно)',
              hintText: '/storage/emulated/0/Android/…/model.gguf',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          if (_extHintPath.isNotEmpty)
            _HintCard(
              icon: Icons.folder_outlined,
              text: 'Для автоматического обнаружения поместите модель в:\n$_extHintPath',
            ),
          const SizedBox(height: 12),
          // Current model status
          Consumer<ChatProvider>(
            builder: (_, provider, __) => _StatusRow(
              ok: provider.isModelReady,
              text: provider.isModelReady
                  ? 'Модель загружена'
                  : provider.statusText,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _savingModel ? null : _saveModelPath,
            icon: _savingModel
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Сохранить путь'),
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
            hint: 'https://mcp.rakulka.ru/mcp',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtrl,
            obscureText: _obscureToken,
            decoration: InputDecoration(
              labelText: 'Bearer Token',
              hintText: 'Секретный токен доступа',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscureToken ? Icons.visibility : Icons.visibility_off),
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

          // ── About ───────────────────────────────────────────────────────────
          const _SectionHeader('О приложении'),
          const SizedBox(height: 8),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.psychology_outlined),
            title: Text('AI Assistant'),
            subtitle: Text('Офлайн-ассистент на LFM2 1.2B Tool\nCactus SDK + MCP (dav-mcp)'),
            isThreeLine: true,
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

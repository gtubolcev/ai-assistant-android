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
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _obscureToken = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('mcp_url') ?? '';
      _tokenCtrl.text = prefs.getString('mcp_token') ?? '';
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
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
      setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          // MCP connection status
          Consumer<ChatProvider>(
            builder: (_, provider, __) {
              final connected = provider.isMcpConnected;
              return Row(
                children: [
                  Icon(
                    connected ? Icons.circle : Icons.circle_outlined,
                    size: 12,
                    color: connected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    provider.statusText,
                    style: TextStyle(
                      fontSize: 12,
                      color: connected ? Colors.green : Colors.grey,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
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
            subtitle: Text('Офлайн-ассистент на LFM2.5-1.2B\nCactus SDK + MCP (dav-mcp)'),
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

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
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _pathCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('caldav_url') ?? '';
      _userCtrl.text = prefs.getString('caldav_user') ?? '';
      _passCtrl.text = prefs.getString('caldav_pass') ?? '';
      _pathCtrl.text = prefs.getString('caldav_path') ?? '/calendars/';
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await context.read<ChatProvider>().saveCalDavConfig(
          url: _urlCtrl.text.trim(),
          user: _userCtrl.text.trim(),
          pass: _passCtrl.text,
          path: _pathCtrl.text.trim(),
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Настройки сохранены')),
      );
      setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── CalDAV section ──────────────────────────────────────────────
          const _SectionHeader('CalDAV — календарь и задачи'),
          const SizedBox(height: 4),
          const Text(
            'Подключи свой Nextcloud / Radicale / Baikal для управления '
            'событиями и задачами через ассистента.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _Field(
            controller: _urlCtrl,
            label: 'Адрес сервера',
            hint: 'https://nextcloud.example.com/remote.php/dav',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          _Field(
            controller: _userCtrl,
            label: 'Имя пользователя',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passCtrl,
            obscureText: _obscurePass,
            decoration: InputDecoration(
              labelText: 'Пароль',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscurePass ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscurePass = !_obscurePass),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            controller: _pathCtrl,
            label: 'Путь к календарю',
            hint: '/calendars/username/personal/',
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
            label: const Text('Сохранить'),
          ),

          const SizedBox(height: 32),

          // ── About ───────────────────────────────────────────────────────
          const _SectionHeader('О приложении'),
          const SizedBox(height: 8),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.psychology_outlined),
            title: Text('AI Assistant'),
            subtitle: Text('Офлайн-ассистент на LFM2.5-1.2B\nCactus SDK + MCP'),
            isThreeLine: true,
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.lock_outline),
            title: Text('Приватность'),
            subtitle: Text(
                'Модель работает полностью на устройстве.\nДанные не покидают телефон.'),
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

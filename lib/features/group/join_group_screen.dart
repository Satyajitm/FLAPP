import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/group_providers.dart';

/// Join group via passphrase screen.
class JoinGroupScreen extends ConsumerStatefulWidget {
  const JoinGroupScreen({super.key});

  @override
  ConsumerState<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends ConsumerState<JoinGroupScreen> {
  final _passphraseController = TextEditingController();
  bool _obscurePassphrase = true;
  bool _isJoining = false;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  void _joinGroup() {
    final passphrase = _passphraseController.text.trim();
    if (passphrase.isEmpty) return;

    setState(() => _isJoining = true);
    ref.read(groupManagerProvider).joinGroup(passphrase);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Group')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Join an existing group',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter the passphrase shared by your group creator.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _passphraseController,
              obscureText: _obscurePassphrase,
              decoration: InputDecoration(
                labelText: 'Group Passphrase',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassphrase ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(() => _obscurePassphrase = !_obscurePassphrase);
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isJoining ? null : _joinGroup,
              icon: _isJoining
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(_isJoining ? 'Joining...' : 'Join Group'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// Create group + show passphrase screen.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _passphraseController = TextEditingController();
  String? _generatedPassphrase;
  bool _obscurePassphrase = true;

  @override
  void dispose() {
    _nameController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  void _createGroup() {
    final name = _nameController.text.trim();
    final passphrase = _passphraseController.text.trim();
    if (passphrase.isEmpty) return;

    // TODO: Call groupManager.createGroup(passphrase, groupName: name)
    // Then navigate to main app
    Navigator.of(context).pop(passphrase);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Group')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Create a new Fluxon group',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Share the passphrase with your group members so they can join.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Group Name (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.group),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passphraseController,
              obscureText: _obscurePassphrase,
              decoration: InputDecoration(
                labelText: 'Passphrase',
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
                helperText: 'Use a memorable phrase your group can share verbally',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _createGroup,
              icon: const Icon(Icons.add),
              label: const Text('Create Group'),
            ),
          ],
        ),
      ),
    );
  }
}

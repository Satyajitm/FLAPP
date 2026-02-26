import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/group_providers.dart';
import 'share_group_screen.dart';

/// Create group screen.
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _passphraseController = TextEditingController();
  bool _obscurePassphrase = true;
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  String? _passphraseError;

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    final passphrase = _passphraseController.text.trim();
    if (passphrase.isEmpty) return;

    if (passphrase.length < 8) {
      setState(() => _passphraseError = 'Passphrase must be at least 8 characters');
      return;
    }
    if (passphrase.length > 128) {
      setState(() => _passphraseError = 'Passphrase must be at most 128 characters');
      return;
    }
    setState(() {
      _passphraseError = null;
      _isCreating = true;
    });

    try {
      final group = await ref.read(groupManagerProvider).createGroup(
        passphrase,
        groupName: name.isEmpty ? null : name,
      );
      if (!mounted) return;
      ref.read(activeGroupProvider.notifier).state = group;

      // L12: Reset _isCreating on success so the button is re-enabled if the
      // user navigates back from the share screen.
      setState(() => _isCreating = false);

      // Navigate to the share screen so the creator can share the join code.
      // The passphrase is intentionally NOT passed — it must be shared verbally.
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ShareGroupScreen(group: group),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCreating = false;
        _passphraseError = 'Failed to create group. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hero icon
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.hub_outlined,
                  size: 36,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Create a group',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'You\'ll get a join code to share with your group members.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 36),
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Group Name',
                hintText: 'e.g. Trail Team',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.group_outlined),
                helperText: 'Optional',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passphraseController,
              obscureText: _obscurePassphrase,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                errorText: _passphraseError,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.lock_outlined),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassphrase
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () {
                    setState(() => _obscurePassphrase = !_obscurePassphrase);
                  },
                ),
                helperText: 'Use a phrase your group can share verbally',
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _isCreating ? null : _createGroup,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isCreating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Create Group',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

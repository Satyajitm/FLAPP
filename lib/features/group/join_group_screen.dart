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

  String? _passphraseError;

  void _joinGroup() {
    final passphrase = _passphraseController.text.trim();
    if (passphrase.isEmpty) return;

    if (passphrase.length < 8) {
      setState(() => _passphraseError = 'Passphrase must be at least 8 characters');
      return;
    }
    setState(() => _passphraseError = null);

    setState(() => _isJoining = true);
    final group = ref.read(groupManagerProvider).joinGroup(passphrase);
    ref.read(activeGroupProvider.notifier).state = group;
    Navigator.of(context).pop();
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
                  color: colorScheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.login_outlined,
                  size: 36,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Join a group',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the passphrase shared by your group creator.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 36),
            TextField(
              controller: _passphraseController,
              obscureText: _obscurePassphrase,
              decoration: InputDecoration(
                labelText: 'Group Passphrase',
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
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _isJoining ? null : _joinGroup,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isJoining
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Join Group',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

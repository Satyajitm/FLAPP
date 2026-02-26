import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/providers/group_providers.dart';

/// Join group via passphrase + join code screen.
///
/// The joiner must supply both the group passphrase (shared verbally or via
/// another channel) AND the 26-character join code (typed or scanned from the
/// creator's QR code). Together they reproduce the exact same key as the creator.
class JoinGroupScreen extends ConsumerStatefulWidget {
  const JoinGroupScreen({super.key});

  @override
  ConsumerState<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends ConsumerState<JoinGroupScreen> {
  final _passphraseController = TextEditingController();
  final _joinCodeController = TextEditingController();
  bool _obscurePassphrase = true;
  bool _isJoining = false;

  String? _passphraseError;
  String? _joinCodeError;

  @override
  void dispose() {
    _passphraseController.dispose();
    _joinCodeController.dispose();
    super.dispose();
  }

  static const _validCodeChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  bool _isValidCode(String code) {
    if (code.length != 26) return false;
    return code.split('').every((c) => _validCodeChars.contains(c));
  }

  Future<void> _joinGroup() async {
    final passphrase = _passphraseController.text.trim();
    final joinCode = _joinCodeController.text.trim().toUpperCase();

    var hasError = false;

    if (passphrase.isEmpty) {
      setState(() => _passphraseError = 'Enter the group passphrase');
      hasError = true;
    } else if (passphrase.length < 8) {
      setState(() =>
          _passphraseError = 'Passphrase must be at least 8 characters');
      hasError = true;
    } else if (passphrase.length > 128) {
      setState(() =>
          _passphraseError = 'Passphrase must be at most 128 characters');
      hasError = true;
    } else {
      setState(() => _passphraseError = null);
    }

    if (joinCode.isEmpty) {
      setState(() => _joinCodeError = 'Enter the 26-character join code');
      hasError = true;
    } else if (!_isValidCode(joinCode)) {
      setState(() =>
          _joinCodeError = 'Invalid code — must be 26 characters (A-Z, 2-7)');
      hasError = true;
    } else {
      setState(() => _joinCodeError = null);
    }

    if (hasError) return;

    setState(() => _isJoining = true);
    try {
      final group = await ref.read(groupManagerProvider).joinGroup(
            passphrase,
            joinCode: joinCode,
          );
      if (!mounted) return;
      ref.read(activeGroupProvider.notifier).state = group;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isJoining = false;
        _joinCodeError = 'Invalid join code';
      });
    }
  }

  /// Open the camera to scan a QR code.
  ///
  /// Expects payload `fluxon:<joinCode>:<passphrase>`. On success, fills both
  /// text fields and returns.
  Future<void> _scanQr() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.65,
        child: Stack(
          children: [
            MobileScanner(
              onDetect: (capture) {
                final barcode = capture.barcodes.firstOrNull;
                final raw = barcode?.rawValue;
                if (raw == null) return;
                _parseQrPayload(raw);
                Navigator.of(ctx).pop();
              },
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _parseQrPayload(String raw) {
    // M15: Reject QR payloads that are too long to be valid Fluxon codes.
    if (raw.length > 256) return;
    // Expected format: fluxon:<joinCode>
    // Old format: fluxon:<joinCode>:<passphrase>  — passphrase portion is ignored.
    // The passphrase is never embedded in QR codes; it must be shared verbally.
    if (!raw.startsWith('fluxon:')) return;
    final rest = raw.substring('fluxon:'.length);
    // Ignore anything after the first colon (legacy passphrase portion).
    final colonIdx = rest.indexOf(':');
    final joinCode = (colonIdx >= 0 ? rest.substring(0, colonIdx) : rest)
        .trim()
        .toUpperCase();
    if (joinCode.isEmpty) return;
    setState(() {
      _joinCodeController.text = joinCode;
      // Passphrase must be typed by the user; never auto-populated from QR.
    });
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
              'Scan or type the join code, then enter the passphrase '
              'you received verbally from the group creator.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 36),

            // Passphrase field
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
            const SizedBox(height: 16),

            // Join code field
            TextField(
              controller: _joinCodeController,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Join Code',
                hintText: 'e.g. ABCDE2FGHIJ3KLMNO4PQRST5UV',
                errorText: _joinCodeError,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                helperText: '26-character code shown by the group creator',
              ),
            ),
            const SizedBox(height: 16),

            // Scan QR button
            OutlinedButton.icon(
              onPressed: _scanQr,
              icon: const Icon(Icons.qr_code_scanner_outlined),
              label: const Text('Scan QR'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
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

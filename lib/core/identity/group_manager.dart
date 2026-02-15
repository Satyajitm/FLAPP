import 'dart:async';
import 'dart:typed_data';
import 'group_cipher.dart';
import 'group_storage.dart';
import 'peer_id.dart';

/// Fluxonlink-specific shared-passphrase group system.
///
/// Groups are created/joined with a shared passphrase. The passphrase
/// is used to derive a symmetric group key via Argon2id. Location packets
/// within the group are encrypted with this key so only group members
/// can see each other's location.
///
/// Encryption logic is delegated to [GroupCipher] (SRP).
/// Persistence is delegated to [GroupStorage] (SRP).
class GroupManager {
  final GroupCipher _cipher;
  final GroupStorage _groupStorage;

  GroupManager({GroupCipher? cipher, GroupStorage? groupStorage})
      : _cipher = cipher ?? GroupCipher(),
        _groupStorage = groupStorage ?? GroupStorage();

  /// Active group (null if not in a group).
  FluxonGroup? _activeGroup;

  /// Get the active group.
  FluxonGroup? get activeGroup => _activeGroup;

  /// Whether the user is currently in a group.
  bool get isInGroup => _activeGroup != null;

  /// Restore a previously saved group from secure storage.
  ///
  /// Call this once at app startup (after SodiumInit.init()).
  Future<void> initialize() async {
    final saved = await _groupStorage.loadGroup();
    if (saved == null) return;

    final groupKey = _cipher.deriveGroupKey(saved.passphrase);
    final groupId = _cipher.generateGroupId(saved.passphrase);
    _activeGroup = FluxonGroup(
      id: groupId,
      name: saved.name,
      key: groupKey,
      members: {},
      createdAt: saved.createdAt,
    );
  }

  /// Create a new group with the given passphrase.
  ///
  /// Derives a group key from the passphrase using Argon2id and generates
  /// a random group ID.
  FluxonGroup createGroup(String passphrase, {String? groupName}) {
    final groupKey = _cipher.deriveGroupKey(passphrase);
    final groupId = _cipher.generateGroupId(passphrase);
    final name = groupName ?? 'Fluxon Group';
    final now = DateTime.now();

    _activeGroup = FluxonGroup(
      id: groupId,
      name: name,
      key: groupKey,
      members: {},
      createdAt: now,
    );

    // Persist — fire-and-forget to keep createGroup synchronous
    unawaited(
      _groupStorage.saveGroup(passphrase: passphrase, name: name, createdAt: now),
    );

    return _activeGroup!;
  }

  /// Join an existing group using the passphrase.
  ///
  /// Derives the same group key from the passphrase. If the passphrase
  /// matches, the derived key will be identical to the creator's key,
  /// enabling decryption of group messages.
  FluxonGroup joinGroup(String passphrase, {String? groupName}) {
    // Same derivation — if the passphrase matches, the key matches
    return createGroup(passphrase, groupName: groupName);
  }

  /// Leave the current group.
  void leaveGroup() {
    _activeGroup = null;
    unawaited(_groupStorage.deleteGroup());
  }

  /// Add a discovered member to the active group.
  void addMember(PeerId peerId) {
    _activeGroup?.members.add(peerId);
  }

  /// Remove a member from the active group.
  void removeMember(PeerId peerId) {
    _activeGroup?.members.remove(peerId);
  }

  /// Encrypt data with the group key (for location/emergency broadcasts).
  Uint8List? encryptForGroup(Uint8List plaintext) {
    return _cipher.encrypt(plaintext, _activeGroup?.key);
  }

  /// Decrypt data with the group key.
  Uint8List? decryptFromGroup(Uint8List data) {
    return _cipher.decrypt(data, _activeGroup?.key);
  }
}

/// A Fluxonlink group.
class FluxonGroup {
  /// Unique group identifier (hex string).
  final String id;

  /// Human-readable group name.
  final String name;

  /// 32-byte symmetric encryption key derived from the passphrase.
  final Uint8List key;

  /// Set of member peer IDs.
  final Set<PeerId> members;

  /// When this group was created/joined.
  final DateTime createdAt;

  FluxonGroup({
    required this.id,
    required this.name,
    required this.key,
    required this.members,
    required this.createdAt,
  });
}

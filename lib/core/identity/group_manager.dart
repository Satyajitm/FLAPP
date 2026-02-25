import 'dart:async';
import 'dart:typed_data';
import 'group_cipher.dart';
import 'group_storage.dart';
import 'peer_id.dart';
import '../protocol/message_types.dart';

/// Fluxonlink-specific shared-passphrase group system.
///
/// Groups are created/joined with a shared passphrase. The passphrase
/// is used to derive a symmetric group key via Argon2id. Location packets
/// within the group are encrypted with this key so only group members
/// can see each other's location.
///
/// **Join flow**: the creator receives a [FluxonGroup.joinCode] — a 26-char
/// base32 string encoding the random salt. Joiners must supply both the
/// passphrase AND the join code so they can derive the exact same key.
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
  /// The derived key, group ID, and salt are loaded directly —
  /// no passphrase re-derivation needed.
  Future<void> initialize() async {
    final saved = await _groupStorage.loadGroup();
    if (saved == null) return;

    _activeGroup = FluxonGroup(
      id: saved.groupId,
      name: saved.name,
      key: saved.groupKey,
      salt: saved.salt,
      members: {},
      createdAt: saved.createdAt,
      cipher: _cipher,
    );
  }

  /// Create a new group with the given passphrase.
  ///
  /// Generates a fresh random salt and derives a group key + ID from it.
  /// Returns a [FluxonGroup] whose [FluxonGroup.joinCode] encodes the salt
  /// so joiners can derive the same key.
  FluxonGroup createGroup(String passphrase, {String? groupName}) {
    final salt = _cipher.generateSalt();
    final groupKey = _cipher.deriveGroupKey(passphrase, salt);
    final groupId = _cipher.generateGroupId(passphrase, salt);
    final name = groupName ?? 'Fluxon Group';
    final now = DateTime.now();

    _activeGroup = FluxonGroup(
      id: groupId,
      name: name,
      key: groupKey,
      salt: salt,
      members: {},
      createdAt: now,
      cipher: _cipher,
    );

    // Persist derived key, group ID, and salt — the passphrase is NOT stored.
    unawaited(
      _groupStorage.saveGroup(
        groupKey: groupKey,
        groupId: groupId,
        name: name,
        createdAt: now,
        salt: salt,
      ),
    );

    return _activeGroup!;
  }

  /// Join an existing group using the passphrase and join code.
  ///
  /// The [joinCode] encodes the creator's salt (as base32). Decoding it and
  /// running the same Argon2id derivation yields an identical key to the
  /// creator's, enabling decryption of group messages.
  FluxonGroup joinGroup(
    String passphrase, {
    required String joinCode,
    String? groupName,
  }) {
    final salt = _cipher.decodeSalt(joinCode);
    final groupKey = _cipher.deriveGroupKey(passphrase, salt);
    final groupId = _cipher.generateGroupId(passphrase, salt);
    final name = groupName ?? 'Fluxon Group';
    final now = DateTime.now();

    _activeGroup = FluxonGroup(
      id: groupId,
      name: name,
      key: groupKey,
      salt: salt,
      members: {},
      createdAt: now,
      cipher: _cipher,
    );

    unawaited(
      _groupStorage.saveGroup(
        groupKey: groupKey,
        groupId: groupId,
        name: name,
        createdAt: now,
        salt: salt,
      ),
    );

    return _activeGroup!;
  }

  /// Leave the current group.
  void leaveGroup() {
    _activeGroup = null;
    // HIGH-C2: Evict all cached derived keys from GroupCipher on leave.
    _cipher.clearCache();
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
  ///
  /// MED-C1: Pass the [messageType] as 1-byte associated data so that the
  /// AEAD tag binds the ciphertext to the intended message type.
  Uint8List? encryptForGroup(Uint8List plaintext, {MessageType? messageType}) {
    Uint8List? ad;
    if (messageType != null) {
      ad = Uint8List.fromList([messageType.value]);
    }
    return _cipher.encrypt(plaintext, _activeGroup?.key, additionalData: ad);
  }

  /// Decrypt data with the group key.
  ///
  /// MED-C1: [messageType] must match what was passed to [encryptForGroup].
  Uint8List? decryptFromGroup(Uint8List data, {MessageType? messageType}) {
    Uint8List? ad;
    if (messageType != null) {
      ad = Uint8List.fromList([messageType.value]);
    }
    return _cipher.decrypt(data, _activeGroup?.key, additionalData: ad);
  }
}

/// A Fluxonlink group.
class FluxonGroup {
  /// Unique group identifier (hex string), derived from passphrase + salt.
  final String id;

  /// Human-readable group name.
  final String name;

  /// 32-byte symmetric encryption key derived from the passphrase + salt.
  final Uint8List key;

  /// The random salt used during key derivation.
  ///
  /// Encode this to a join code with [joinCode] so others can derive the
  /// same key.
  final Uint8List salt;

  /// Set of member peer IDs.
  final Set<PeerId> members;

  /// When this group was created/joined.
  final DateTime createdAt;

  final GroupCipher _cipher;

  FluxonGroup({
    required this.id,
    required this.name,
    required this.key,
    required this.salt,
    required this.members,
    required this.createdAt,
    required GroupCipher cipher,
  }) : _cipher = cipher;

  /// 26-character base32 string encoding [salt].
  ///
  /// Share this with the passphrase so other devices can join the group.
  String get joinCode => _cipher.encodeSalt(salt);
}

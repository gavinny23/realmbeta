/// Metadata (no secrets) for one account that's been signed into on
/// this device at some point. This is what the account switcher
/// renders — the actual session tokens live in secure storage,
/// keyed separately by [id], and are never held here.
class SavedAccount {
  final String id; // Supabase auth user id
  final String email;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final DateTime addedAt;
  final DateTime lastActiveAt;

  SavedAccount({
    required this.id,
    required this.email,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    required this.addedAt,
    required this.lastActiveAt,
  });

  SavedAccount copyWith({
    String? username,
    String? displayName,
    String? avatarUrl,
    DateTime? lastActiveAt,
  }) {
    return SavedAccount(
      id: id,
      email: email,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      addedAt: addedAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'email': email,
        'username': username,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'added_at': addedAt.toIso8601String(),
        'last_active_at': lastActiveAt.toIso8601String(),
      };

  factory SavedAccount.fromMap(Map<String, dynamic> map) {
    return SavedAccount(
      id: map['id'] as String,
      email: map['email'] as String? ?? '',
      username: map['username'] as String? ?? '',
      displayName: map['display_name'] as String? ?? '',
      avatarUrl: map['avatar_url'] as String?,
      addedAt: DateTime.tryParse(map['added_at'] as String? ?? '') ??
          DateTime.now(),
      lastActiveAt:
          DateTime.tryParse(map['last_active_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}

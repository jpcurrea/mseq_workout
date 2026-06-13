class Project {
  final int id;
  final String name;
  final String? description;
  final int ownerId;
  final String role; // "owner" | "editor" | "viewer"
  final int memberCount;
  final DateTime createdAt;

  const Project({
    required this.id,
    required this.name,
    this.description,
    required this.ownerId,
    required this.role,
    required this.memberCount,
    required this.createdAt,
  });

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'],
        name: json['name'],
        description: json['description'],
        ownerId: json['owner_id'],
        role: json['role'] ?? 'viewer',
        memberCount: json['member_count'] ?? 1,
        createdAt: DateTime.parse(json['created_at']),
      );

  bool get canWrite => role == 'owner' || role == 'editor';
  bool get isOwner => role == 'owner';
}

class ProjectMember {
  final int userId;
  final String username;
  final String? pictureUrl;
  final String role;
  final DateTime joinedAt;

  const ProjectMember({
    required this.userId,
    required this.username,
    this.pictureUrl,
    required this.role,
    required this.joinedAt,
  });

  factory ProjectMember.fromJson(Map<String, dynamic> json) => ProjectMember(
        userId: json['user_id'],
        username: json['username'],
        pictureUrl: json['picture_url'],
        role: json['role'],
        joinedAt: DateTime.parse(json['joined_at']),
      );
}

class ProjectInvite {
  final int id;
  final String token;
  final String roleToGrant;
  final int useCount;
  final int? maxUses;
  final DateTime? expiresAt;

  const ProjectInvite({
    required this.id,
    required this.token,
    required this.roleToGrant,
    required this.useCount,
    this.maxUses,
    this.expiresAt,
  });

  factory ProjectInvite.fromJson(Map<String, dynamic> json) => ProjectInvite(
        id: json['id'],
        token: json['token'],
        roleToGrant: json['role_to_grant'],
        useCount: json['use_count'],
        maxUses: json['max_uses'],
        expiresAt: json['expires_at'] != null ? DateTime.parse(json['expires_at']) : null,
      );
}

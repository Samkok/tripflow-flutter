/// One row of the `referrals` table, as visible to the REFERRER via RLS.
/// Deliberately carries no referee identity — the UI shows "A friend joined"
/// with dates and status only.
class ReferralEntry {
  final String id;
  final String status; // pending | qualified | banked | rewarded
  final DateTime createdAt;
  final DateTime? qualifiedAt;

  /// Set when the month was earned while the referrer was on active paid
  /// coverage — it pays out automatically when that coverage lapses.
  final DateTime? bankedAt;
  final DateTime? rewardedAt;

  const ReferralEntry({
    required this.id,
    required this.status,
    required this.createdAt,
    this.qualifiedAt,
    this.bankedAt,
    this.rewardedAt,
  });

  factory ReferralEntry.fromJson(Map<String, dynamic> json) => ReferralEntry(
        id: json['id'] as String,
        status: json['status'] as String? ?? 'pending',
        createdAt: DateTime.parse(json['created_at'] as String),
        qualifiedAt: json['qualified_at'] != null
            ? DateTime.tryParse(json['qualified_at'] as String)
            : null,
        bankedAt: json['banked_at'] != null
            ? DateTime.tryParse(json['banked_at'] as String)
            : null,
        rewardedAt: json['rewarded_at'] != null
            ? DateTime.tryParse(json['rewarded_at'] as String)
            : null,
      );

  bool get isRewarded => status == 'rewarded';
  bool get isBanked => status == 'banked';
}

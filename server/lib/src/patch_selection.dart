import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A patch of one release on the requested channel that has an artifact for
/// the requesting device's platform and arch.
class PatchCandidate {
  const PatchCandidate({
    required this.id,
    required this.number,
    required this.rolloutPercentage,
    required this.isRolledBack,
  });

  final int id;
  final int number;

  /// Null means 100.
  final double? rolloutPercentage;
  final bool isRolledBack;
}

/// Where [clientId] falls in [patchId]'s rollout, in 0..9999.
///
/// Stable per (patch, install), so a device stays inside or outside a
/// rollout across checks, and raising the percentage only adds devices.
/// Salting with the patch id gives every rollout an independent cohort.
int rolloutBucket(int patchId, String clientId) {
  final digest = sha256.convert(utf8.encode('$patchId:$clientId')).bytes;
  final value =
      (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
  return value % 10000;
}

bool isInRollout(PatchCandidate patch, String? clientId) {
  final pct = patch.rolloutPercentage ?? 100;
  if (pct >= 100) return true;
  // An updater too old to send client_id can't be bucketed, so it only gets
  // fully rolled out patches.
  if (clientId == null || clientId.isEmpty) return false;
  return rolloutBucket(patch.id, clientId) < (pct * 100).round();
}

/// The patch a device should run: the newest one that is not rolled back
/// and whose rollout includes the device. When the newest patch's rollout
/// excludes the device, an older one still applies, as it did before the
/// new patch was published.
///
/// [legacyPatchNumber] is the pre-`current_patch_number` field: when set,
/// only patches numbered above it are offered.
PatchCandidate? selectPatch(
  List<PatchCandidate> candidates, {
  String? clientId,
  int? legacyPatchNumber,
}) {
  final sorted = [...candidates]..sort((a, b) => b.number.compareTo(a.number));
  for (final patch in sorted) {
    if (patch.isRolledBack) continue;
    if (!isInRollout(patch, clientId)) continue;
    if (legacyPatchNumber != null && patch.number <= legacyPatchNumber) {
      return null;
    }
    return patch;
  }
  return null;
}

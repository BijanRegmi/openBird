import 'package:openbird_server/src/patch_selection.dart';
import 'package:test/test.dart';

PatchCandidate p(int number, {double? pct, bool rolledBack = false}) =>
    PatchCandidate(
      id: 100 + number,
      number: number,
      rolloutPercentage: pct,
      isRolledBack: rolledBack,
    );

void main() {
  test('offers the newest patch', () {
    expect(selectPatch([p(1), p(3), p(2)], clientId: 'c')!.number, 3);
  });

  test('skips rolled back patches', () {
    expect(
      selectPatch([p(1), p(2, rolledBack: true)], clientId: 'c')!.number,
      1,
    );
    expect(selectPatch([p(1, rolledBack: true)], clientId: 'c'), isNull);
  });

  test('falls back to an older patch outside a partial rollout', () {
    final excluded = List.generate(
      1000,
      (i) => 'client-$i',
    ).firstWhere((c) => !isInRollout(p(2, pct: 10), c));
    expect(selectPatch([p(1), p(2, pct: 10)], clientId: excluded)!.number, 1);
  });

  test('partial rollouts reach about their percentage, stably', () {
    final patch = p(1, pct: 25);
    final clients = List.generate(20000, (i) => 'install-$i');
    final included = clients.where((c) => isInRollout(patch, c)).length;
    expect(included / clients.length, closeTo(0.25, 0.02));
    expect(
      clients.every((c) => isInRollout(patch, c) == isInRollout(patch, c)),
      isTrue,
    );
  });

  test('raising a rollout only adds devices', () {
    final clients = List.generate(5000, (i) => 'install-$i');
    final at10 = clients.where((c) => isInRollout(p(1, pct: 10), c)).toSet();
    final at50 = clients.where((c) => isInRollout(p(1, pct: 50), c)).toSet();
    expect(at50.containsAll(at10), isTrue);
  });

  test('updaters without client_id get only fully rolled out patches', () {
    expect(selectPatch([p(1), p(2, pct: 99.99)], clientId: null)!.number, 1);
  });

  test('legacy patch_number only offers newer patches', () {
    expect(
      selectPatch([p(1), p(2)], clientId: 'c', legacyPatchNumber: 2),
      isNull,
    );
    expect(
      selectPatch([p(1), p(2)], clientId: 'c', legacyPatchNumber: 1)!.number,
      2,
    );
  });
}

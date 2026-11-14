import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../auth.dart';
import '../http.dart';
import '../services.dart';

/// The spec's metrics operations, computed from what devices tell us:
/// `devices` and `device_activity` (recorded on each patch check, keyed by
/// the updater's anonymous per-install `client_id`) and `patch_events`.
class MetricsApi {
  MetricsApi(this.s);
  final Services s;

  static const _granularities = {'hour', 'day', 'week'};

  /// `start`/`end`/`granularity` query parameters; the default range is the
  /// last 30 days. The previous window is the same length, just before.
  ({DateTime start, DateTime end, String? granularity}) _range(Request r) {
    final q = r.url.queryParameters;
    final end =
        DateTime.tryParse(q['end'] ?? '')?.toUtc() ?? DateTime.now().toUtc();
    final start =
        DateTime.tryParse(q['start'] ?? '')?.toUtc() ??
        end.subtract(const Duration(days: 30));
    if (!start.isBefore(end)) {
      throw ApiError.badRequest('start must be before end.');
    }
    final g = q['granularity'];
    if (g != null && !_granularities.contains(g)) {
      throw ApiError.badRequest('granularity must be hour, day or week.');
    }
    return (start: start, end: end, granularity: g);
  }

  Future<String> _app(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    return appId;
  }

  // Patch installs and downloads, from updater events.

  Future<Response> getAppPatchInstalls(Request r) =>
      _patchMetric(r, '__patch_install__', groupKey: 'release');
  Future<Response> getAppPatchDownloads(Request r) =>
      _patchMetric(r, '__patch_download__', groupKey: 'release');
  Future<Response> getReleasePatchInstalls(Request r) =>
      _patchMetric(r, '__patch_install__', groupKey: 'patch', release: true);
  Future<Response> getReleasePatchDownloads(Request r) =>
      _patchMetric(r, '__patch_download__', groupKey: 'patch', release: true);

  Future<Response> _patchMetric(
    Request request,
    String type, {
    required String groupKey,
    bool release = false,
  }) async {
    final appId = await _app(request);
    String? version;
    if (release) {
      final row = await s.access.requireRelease(
        appId,
        pathInt(request, 'releaseId'),
      );
      version = row['version'] as String;
    }
    final range = _range(request);
    final groupBy = request.url.queryParameters['group_by'];
    if (groupBy != null && groupBy != groupKey) {
      throw ApiError.badRequest('group_by must be $groupKey.');
    }
    final groupColumn = groupKey == 'release'
        ? 'release_version'
        : 'patch_number::text';
    final where =
        'app_id = @app AND type = @type AND occurred_at >= @start AND occurred_at < @end'
        '${version != null ? ' AND release_version = @rv' : ''}';

    Future<PatchMetricWindow> window(DateTime start, DateTime end) async {
      final params = {
        'app': appId,
        'type': type,
        'start': start,
        'end': end,
        'rv': ?version,
      };
      final total = await s.db.one(
        'SELECT count(*) AS n FROM patch_events WHERE $where',
        params,
      );
      return PatchMetricWindow(
        count: total!['n'] as int,
        range: MetricsRange(start: start, end: end),
        timeSeries: range.granularity == null
            ? null
            : [
                for (final row in await s.db.query(
                  "SELECT date_trunc('${range.granularity}', occurred_at) AS period, count(*) AS n "
                  'FROM patch_events WHERE $where GROUP BY 1 ORDER BY 1',
                  params,
                ))
                  PatchMetricTimeSeriesEntry(
                    period: (row['period'] as DateTime).toUtc(),
                    count: row['n'] as int,
                  ),
              ],
      );
    }

    final current = await window(range.start, range.end);
    List<PatchMetricBreakdownEntry>? breakdown;
    if (groupBy != null) {
      final params = {
        'app': appId,
        'type': type,
        'start': range.start,
        'end': range.end,
        'rv': ?version,
      };
      final series = <String, List<PatchMetricTimeSeriesEntry>>{};
      if (range.granularity != null) {
        for (final row in await s.db.query(
          "SELECT $groupColumn AS g, date_trunc('${range.granularity}', occurred_at) AS period, count(*) AS n "
          'FROM patch_events WHERE $where GROUP BY 1, 2 ORDER BY 2',
          params,
        )) {
          (series[row['g'] as String] ??= []).add(
            PatchMetricTimeSeriesEntry(
              period: (row['period'] as DateTime).toUtc(),
              count: row['n'] as int,
            ),
          );
        }
      }
      breakdown = [
        for (final row in await s.db.query(
          'SELECT $groupColumn AS g, count(*) AS n FROM patch_events WHERE $where GROUP BY 1 ORDER BY 2 DESC',
          params,
        ))
          PatchMetricBreakdownEntry(
            groupBy: groupKey,
            groupValue: row['g'] as String,
            count: row['n'] as int,
            timeSeries: range.granularity == null
                ? null
                : series[row['g']] ?? const [],
          ),
      ];
    }
    final length = range.end.difference(range.start);
    final previous = await window(range.start.subtract(length), range.start);
    return jsonResponse(
      GetPatchMetricResponse(
        asOf: DateTime.now().toUtc(),
        granularity: range.granularity,
        current: PatchMetricCurrentWindow(
          count: current.count,
          range: current.range,
          timeSeries: current.timeSeries,
          breakdown: breakdown,
        ),
        previous: previous,
      ).toJson(),
    );
  }

  // Devices, from patch-check activity.

  Future<Response> getUniqueUsers(Request request) async {
    final appId = await _app(request);
    final range = _range(request);
    final groupBy = request.url.queryParameters['group_by'];
    if (groupBy != null &&
        groupBy != 'platform' &&
        groupBy != 'release_version') {
      throw ApiError.badRequest(
        'group_by must be platform or release_version.',
      );
    }
    const where = 'app_id = @app AND hour >= @start AND hour < @end';

    Future<UniqueUsersWindow> window(DateTime start, DateTime end) async {
      final params = {'app': appId, 'start': start, 'end': end};
      final total = await s.db.one(
        'SELECT count(DISTINCT client_id) AS n FROM device_activity WHERE $where',
        params,
      );
      return UniqueUsersWindow(
        uniqueUsers: total!['n'] as int,
        range: MetricsRange(start: start, end: end),
        timeSeries: range.granularity == null
            ? null
            : [
                for (final row in await s.db.query(
                  "SELECT date_trunc('${range.granularity}', hour) AS period, count(DISTINCT client_id) AS n "
                  'FROM device_activity WHERE $where GROUP BY 1 ORDER BY 1',
                  params,
                ))
                  UniqueUsersTimeSeriesEntry(
                    period: (row['period'] as DateTime).toUtc(),
                    uniqueUsers: row['n'] as int,
                  ),
              ],
      );
    }

    final current = await window(range.start, range.end);
    List<UniqueUsersBreakdownEntry>? breakdown;
    if (groupBy != null) {
      final params = {'app': appId, 'start': range.start, 'end': range.end};
      final series = <String, List<UniqueUsersTimeSeriesEntry>>{};
      if (range.granularity != null) {
        for (final row in await s.db.query(
          "SELECT $groupBy AS g, date_trunc('${range.granularity}', hour) AS period, "
          'count(DISTINCT client_id) AS n FROM device_activity WHERE $where GROUP BY 1, 2 ORDER BY 2',
          params,
        )) {
          (series[row['g'] as String] ??= []).add(
            UniqueUsersTimeSeriesEntry(
              period: (row['period'] as DateTime).toUtc(),
              uniqueUsers: row['n'] as int,
            ),
          );
        }
      }
      breakdown = [
        for (final row in await s.db.query(
          'SELECT $groupBy AS g, count(DISTINCT client_id) AS n FROM device_activity '
          'WHERE $where GROUP BY 1 ORDER BY 2 DESC',
          params,
        ))
          UniqueUsersBreakdownEntry(
            groupBy: groupBy,
            groupValue: row['g'] as String,
            uniqueUsers: row['n'] as int,
            timeSeries: range.granularity == null
                ? null
                : series[row['g']] ?? const [],
          ),
      ];
    }
    final length = range.end.difference(range.start);
    return jsonResponse(
      GetUniqueUsersResponse(
        asOf: DateTime.now().toUtc(),
        granularity: range.granularity,
        current: UniqueUsersCurrentWindow(
          uniqueUsers: current.uniqueUsers,
          range: current.range,
          timeSeries: current.timeSeries,
          breakdown: breakdown,
        ),
        previous: await window(range.start.subtract(length), range.start),
      ).toJson(),
    );
  }

  /// Devices seen in the last 30 days, by the release they run.
  Future<Response> getVersionDistribution(Request request) async {
    final appId = await _app(request);
    const days = 30;
    final rows = await s.db.query(
      'SELECT release_version, count(*) AS n FROM devices '
      "WHERE app_id = @app AND last_seen >= now() - interval '$days days' "
      'GROUP BY 1 ORDER BY 2 DESC',
      {'app': appId},
    );
    final total = rows.fold<int>(0, (sum, r) => sum + (r['n'] as int));
    return jsonResponse(
      GetVersionDistributionResponse(
        entries: [
          for (final row in rows)
            VersionDistributionEntry(
              releaseVersion: row['release_version'] as String?,
              deviceCount: row['n'] as int,
              percentage: total == 0 ? 0 : (row['n'] as int) * 100 / total,
            ),
        ],
        totalDevices: total,
        activeWindowDays: days,
        asOf: DateTime.now().toUtc(),
      ).toJson(),
    );
  }

  /// Installs first seen in the last 30 days, and the 30 before.
  Future<Response> getNewDevices(Request request) async {
    final appId = await _app(request);
    const days = 30;
    final row = await s.db.one(
      'SELECT '
      " count(*) FILTER (WHERE first_seen >= now() - interval '$days days') AS current, "
      " count(*) FILTER (WHERE first_seen >= now() - interval '${days * 2} days' "
      "   AND first_seen < now() - interval '$days days') AS previous "
      'FROM devices WHERE app_id = @app',
      {'app': appId},
    );
    return jsonResponse(
      GetNewDevicesResponse(
        current: row!['current'] as int,
        previous: row['previous'] as int,
        windowDays: days,
        asOf: DateTime.now().toUtc(),
      ).toJson(),
    );
  }

  static const _lookbackDays = 14;

  /// Average active installs per UTC hour of day over two weeks, and the
  /// quietest 4-hour window: the least disruptive time to start a rollout.
  Future<Response> getActiveHours(Request request) async {
    final appId = await _app(request);
    final rows = await s.db.query(
      "SELECT extract(hour FROM hour AT TIME ZONE 'UTC')::int AS h, count(*) AS n FROM device_activity "
      "WHERE app_id = @app AND hour >= now() - interval '$_lookbackDays days' GROUP BY 1",
      {'app': appId},
    );
    final counts = List<double>.filled(24, 0);
    for (final row in rows) {
      counts[row['h'] as int] = (row['n'] as int) / _lookbackDays;
    }
    const windowLength = 4;
    int? busiest;
    int? quietest;
    if (rows.isNotEmpty) {
      busiest = 0;
      quietest = 0;
      var quietSum = double.infinity;
      for (var h = 0; h < 24; h++) {
        if (counts[h] > counts[busiest!]) busiest = h;
        var sum = 0.0;
        for (var i = 0; i < windowLength; i++) {
          sum += counts[(h + i) % 24];
        }
        if (sum < quietSum) {
          quietSum = sum;
          quietest = h;
        }
      }
    }
    return jsonResponse(
      GetActiveHoursResponse(
        hourly: [
          for (var h = 0; h < 24; h++)
            ActiveHourEntry(hourUtc: h, averageActiveDevices: counts[h]),
        ],
        recommendedWindowStartUtc: quietest,
        recommendedWindowLengthHours: windowLength,
        busiestHourUtc: busiest,
        lookbackDays: _lookbackDays,
        asOf: DateTime.now().toUtc(),
      ).toJson(),
    );
  }

  /// Average active installs per UTC weekday (0 = Sunday) and hour.
  Future<Response> getActivityHeatmap(Request request) async {
    final appId = await _app(request);
    const lookback = 28;
    final rows = await s.db.query(
      "SELECT extract(dow FROM hour AT TIME ZONE 'UTC')::int AS d, "
      "extract(hour FROM hour AT TIME ZONE 'UTC')::int AS h, count(*) AS n FROM device_activity "
      "WHERE app_id = @app AND hour >= now() - interval '$lookback days' GROUP BY 1, 2",
      {'app': appId},
    );
    final cells = [
      for (final row in rows)
        ActivityHeatmapCell(
          dayOfWeekUtc: row['d'] as int,
          hourUtc: row['h'] as int,
          averageActiveDevices: (row['n'] as int) / (lookback / 7),
        ),
    ];
    ActivityHeatmapCell? top;
    for (final c in cells) {
      if (top == null || c.averageActiveDevices > top.averageActiveDevices) {
        top = c;
      }
    }
    return jsonResponse(
      GetActivityHeatmapResponse(
        cells: cells,
        busiestDayOfWeekUtc: top?.dayOfWeekUtc,
        busiestHourUtc: top?.hourUtc,
        lookbackDays: lookback,
        asOf: DateTime.now().toUtc(),
      ).toJson(),
    );
  }

  /// Share of a release's active installs running each of its patches.
  Future<Response> getPatchAdoption(Request request) async {
    final appId = await _app(request);
    final range = _range(request);
    final latest = await s.db.one(
      'SELECT version FROM releases WHERE app_id = @app ORDER BY created_at DESC, id DESC LIMIT 1',
      {'app': appId},
    );
    final version =
        request.url.queryParameters['release_version'] ??
        latest?['version'] as String?;
    if (version == null) throw ApiError.notFound('Release');
    final release = await s.db.one(
      'SELECT id FROM releases WHERE app_id = @app AND version = @v',
      {'app': appId, 'v': version},
    );
    if (release == null) throw ApiError.notFound('Release');
    final patches = await s.db.query(
      'SELECT p.number, p.is_rolled_back, '
      ' ARRAY(SELECT DISTINCT platform FROM patch_artifacts pa WHERE pa.patch_id = p.id) AS platforms '
      'FROM patches p WHERE p.release_id = @r ORDER BY p.number',
      {'r': release['id']},
    );
    final period = range.granularity == null
        ? 'NULL::timestamptz'
        : "date_trunc('${range.granularity}', hour)";
    final rows = await s.db.query(
      'SELECT $period AS period, patch_number, count(DISTINCT client_id) AS n FROM device_activity '
      'WHERE app_id = @app AND release_version = @v AND hour >= @start AND hour < @end '
      'GROUP BY 1, 2',
      {'app': appId, 'v': version, 'start': range.start, 'end': range.end},
    );
    final targets = <DateTime?, int>{};
    for (final row in await s.db.query(
      'SELECT $period AS period, count(DISTINCT client_id) AS n FROM device_activity '
      'WHERE app_id = @app AND release_version = @v AND hour >= @start AND hour < @end GROUP BY 1',
      {'app': appId, 'v': version, 'start': range.start, 'end': range.end},
    )) {
      targets[(row['period'] as DateTime?)?.toUtc()] = row['n'] as int;
    }
    final periods = targets.keys.toList()
      ..sort((a, b) => (a ?? DateTime(0)).compareTo(b ?? DateTime(0)));
    return jsonResponse(
      GetPatchAdoptionResponse(
        releaseVersion: version,
        isLatest: version == latest?['version'],
        granularity: range.granularity,
        range: MetricsRange(start: range.start, end: range.end),
        asOf: DateTime.now().toUtc(),
        patches: [
          for (final patch in patches)
            PatchAdoptionEntry(
              patchNumber: patch['number'] as int,
              isRolledBack: patch['is_rolled_back'] as bool,
              targetPlatforms: [
                for (final p in patch['platforms'] as List)
                  ReleasePlatform.fromJson(p as String),
              ],
              series: [
                for (final p in periods)
                  () {
                    final devices = rows
                        .where(
                          (r) =>
                              (r['period'] as DateTime?)?.toUtc() == p &&
                              r['patch_number'] == patch['number'],
                        )
                        .fold<int>(0, (sum, r) => sum + (r['n'] as int));
                    final target = targets[p] ?? 0;
                    return PatchAdoptionPoint(
                      period: p,
                      devices: devices,
                      target: target,
                      adoptionPct: target == 0 ? 0 : devices * 100 / target,
                    );
                  }(),
              ],
            ),
        ],
      ).toJson(),
    );
  }
}

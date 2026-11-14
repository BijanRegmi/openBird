-- Demo data for the console: a separate "Demo Store" app in organization
-- :org with releases, patches, channels and ~45 days of synthetic device
-- activity and events. Never touches other apps. Safe to re-run (it
-- replaces the demo app).
--
--   docker compose exec -T postgres psql -U openbird -v org=1 < tool/seed_demo.sql
--
-- Patch downloads for the demo app 404: the artifacts are rows only.

\set app '''00000000-0000-4000-8000-00000000d3a0'''

BEGIN;
DELETE FROM apps WHERE id = :app;
DELETE FROM devices WHERE app_id = :app;
DELETE FROM device_activity WHERE app_id = :app;
DELETE FROM patch_events WHERE app_id = :app;

INSERT INTO apps (id, organization_id, display_name, created_at)
VALUES (:app, :org, 'Demo Store', now() - interval '60 days');
INSERT INTO channels (app_id, name) VALUES (:app, 'stable'), (:app, 'beta'), (:app, 'qa');

INSERT INTO releases (app_id, version, flutter_revision, flutter_version, created_at, notes) VALUES
  (:app, '2.3.0+41', '6f0092351b8eac9446132ebcafb82fde73f305f7', '3.47.9', now() - interval '58 days', 'Checkout redesign'),
  (:app, '2.4.0+44', '6f0092351b8eac9446132ebcafb82fde73f305f7', '3.47.9', now() - interval '31 days', 'Wishlist and saved carts'),
  (:app, '2.5.0+47', '6f0092351b8eac9446132ebcafb82fde73f305f7', '3.47.9', now() - interval '12 days', 'Faster startup, new search');

INSERT INTO release_platforms (release_id, platform, status, signing_mode)
SELECT r.id, p, 'active', 'managed' FROM releases r, unnest(ARRAY['android', 'ios']) p WHERE r.app_id = :app;

-- Patches: (release, number, channel, rollout, rolled back, age in days, notes)
CREATE TEMP TABLE demo_patches (version text, number int, channel text, pct float, rb bool, age int, notes text);
INSERT INTO demo_patches VALUES
  ('2.3.0+41', 1, 'stable', 100, false, 55, 'Fix crash on empty cart'),
  ('2.3.0+41', 2, 'stable', 100, false, 44, 'Price rounding'),
  ('2.4.0+44', 1, 'stable', 100, false, 27, 'Wishlist sync race'),
  ('2.4.0+44', 2, 'stable', 100, true, 20, 'Promo banner (rolled back: layout overflow on small screens)'),
  ('2.4.0+44', 3, 'stable', 100, false, 18, 'Promo banner, fixed'),
  ('2.5.0+47', 1, 'stable', 100, false, 9, 'Search ranking tweak'),
  ('2.5.0+47', 2, 'stable', 35, false, 2, 'New onboarding copy'),
  ('2.5.0+47', 3, 'beta', 100, false, 1, 'Experimental recommendations');

INSERT INTO patches (release_id, number, channel_id, rollout_percentage, is_rolled_back, notes, created_at)
SELECT r.id, d.number, c.id, d.pct, d.rb, d.notes, now() - make_interval(days => d.age)
FROM demo_patches d
JOIN releases r ON r.app_id = :app AND r.version = d.version
JOIN channels c ON c.app_id = :app AND c.name = d.channel;

INSERT INTO patch_artifacts (patch_id, platform, arch, hash, size, storage_key, uploaded_at, created_at)
SELECT p.id, a.platform, a.arch, md5(p.id::text || a.arch) || md5(a.arch || p.id::text), 4000 + (p.id * 37) % 9000,
       'demo/' || p.id || '/' || a.arch, p.created_at, p.created_at
FROM patches p JOIN releases r ON r.id = p.release_id,
     (VALUES ('android', 'aarch64'), ('android', 'arm'), ('android', 'x86_64'), ('ios', 'aarch64')) a(platform, arch)
WHERE r.app_id = :app;

-- 1,800 installs: platform, the release each upgraded to over time.
CREATE TEMP TABLE demo_devices AS
SELECT 'demo-' || lpad(i::text, 5, '0') AS client_id,
       CASE WHEN random() < 0.62 THEN 'android' ELSE 'ios' END AS platform,
       now() - make_interval(days => (random() * 45)::int) AS first_seen,
       random() AS loyalty
FROM generate_series(1, 1800) i;

-- Hourly activity: each install is active on a share of days, mostly in
-- the local evening (UTC 16-22), at the release current on that day.
CREATE TEMP TABLE demo_hours AS
SELECT d.client_id, d.platform,
       date_trunc('hour', day + make_interval(hours => (CASE WHEN random() < 0.7 THEN 16 + (random() * 6)::int ELSE (random() * 23)::int END))) AS hour
FROM demo_devices d,
     generate_series(date_trunc('day', d.first_seen), date_trunc('day', now()), interval '1 day') day
WHERE random() < 0.25 + d.loyalty * 0.5
  AND day + interval '23 hours' > d.first_seen;
DELETE FROM demo_hours WHERE hour > now();

INSERT INTO device_activity (app_id, client_id, hour, release_version, platform, patch_number)
SELECT :app, h.client_id, h.hour, v.version, h.platform, v.patch
FROM demo_hours h
CROSS JOIN LATERAL (
  SELECT r.version,
         (SELECT max(p.number) FROM patches p
           WHERE p.release_id = r.id AND NOT p.is_rolled_back AND p.channel_id IS NOT NULL
             AND p.created_at + interval '20 hours' < h.hour
             AND (p.rollout_percentage >= 100 OR abs(hashtext(h.client_id || p.id)) % 100 < p.rollout_percentage)
             AND (SELECT name FROM channels WHERE id = p.channel_id) = 'stable') AS patch
  FROM releases r
  WHERE r.app_id = :app
    AND r.created_at <= h.hour - make_interval(days => (abs(hashtext(h.client_id)) % 31))
  ORDER BY r.created_at DESC LIMIT 1
) v
ON CONFLICT DO NOTHING;

INSERT INTO devices (app_id, client_id, first_seen, last_seen, release_version, platform, arch, patch_number)
SELECT DISTINCT ON (a.client_id) :app, a.client_id, d.first_seen, a.hour, a.release_version, a.platform,
       CASE WHEN a.platform = 'ios' THEN 'aarch64' ELSE (ARRAY['aarch64', 'aarch64', 'aarch64', 'arm', 'x86_64'])[1 + abs(hashtext(a.client_id)) % 5] END,
       a.patch_number
FROM device_activity a JOIN demo_devices d USING (client_id)
WHERE a.app_id = :app
ORDER BY a.client_id, a.hour DESC;

-- One download and install event per install per patch it moved onto,
-- plus a few failures.
INSERT INTO patch_events (event_id, app_id, release_version, patch_number, platform, arch, client_id, type, occurred_at)
SELECT md5(t || a.client_id || a.release_version || a.patch_number), :app, a.release_version, a.patch_number, a.platform,
       dv.arch, a.client_id, t, first_hour + make_interval(mins => CASE t WHEN '__patch_download__' THEN 1 ELSE 3 END)
FROM (
  SELECT client_id, release_version, patch_number, platform, min(hour) AS first_hour
  FROM device_activity WHERE app_id = :app AND patch_number IS NOT NULL
  GROUP BY 1, 2, 3, 4
) a
JOIN devices dv ON dv.app_id = :app AND dv.client_id = a.client_id,
     unnest(ARRAY['__patch_download__', '__patch_install__']) t
ON CONFLICT DO NOTHING;

INSERT INTO patch_events (event_id, app_id, release_version, patch_number, platform, arch, client_id, type, message, failure_category, occurred_at)
SELECT md5('fail' || i), :app, '2.5.0+47', 2, 'android', 'arm', 'demo-' || lpad((i * 7)::text, 5, '0'),
       CASE WHEN i % 3 = 0 THEN '__patch_update_failure__' ELSE '__patch_install_failure__' END,
       CASE WHEN i % 3 = 0 THEN 'Network request failed; the server could not be reached.' ELSE 'Patch file is corrupt' END,
       CASE WHEN i % 3 = 0 THEN 'network' ELSE 'corrupt_patch' END,
       now() - make_interval(hours => i * 5)
FROM generate_series(1, 9) i;

INSERT INTO build_runs (app_id, run_id, command, platform, outcome, payload, created_at)
SELECT :app, md5(r.version || p), CASE WHEN p = 'ios' THEN 'release' ELSE 'release' END, p, 'succeeded',
       jsonb_build_object('release_id', r.id, 'duration_ms', 180000 + (r.id % 7) * 21000, 'dry_run', false,
         'started_at', r.created_at, 'metadata', jsonb_build_object('ci', 'github_actions', 'os', 'macos-15', 'shorebird_version', '1.6.140'),
         'build_flags', jsonb_build_object('dart_define_count', 3, 'dart_defines', '{}'::jsonb)),
       r.created_at
FROM releases r, unnest(ARRAY['android', 'ios']) p WHERE r.app_id = :app;

INSERT INTO build_runs (app_id, run_id, command, platform, outcome, payload, created_at)
SELECT :app, md5(p.id::text || x), 'patch', x, CASE WHEN p.number = 2 AND r.version = '2.4.0+44' AND x = 'ios' THEN 'failed' ELSE 'succeeded' END,
       jsonb_build_object('release_id', r.id, 'patch_id', p.id, 'duration_ms', 95000 + (p.id % 5) * 13000, 'dry_run', false,
         'reason', CASE WHEN p.number = 2 AND r.version = '2.4.0+44' AND x = 'ios' THEN 'native_diffs' END,
         'started_at', p.created_at, 'metadata', jsonb_build_object('ci', 'github_actions', 'shorebird_version', '1.6.140')),
       p.created_at
FROM patches p JOIN releases r ON r.id = p.release_id, unnest(ARRAY['android', 'ios']) x WHERE r.app_id = :app;

COMMIT;

SELECT (SELECT count(*) FROM devices WHERE app_id = :app) AS devices,
       (SELECT count(*) FROM device_activity WHERE app_id = :app) AS activity_rows,
       (SELECT count(*) FROM patch_events WHERE app_id = :app) AS events;

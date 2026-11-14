import { AlertTriangle, Download, Layers, Rocket, Smartphone, Users } from 'lucide-react'
import { Link } from 'react-router-dom'
import {
  useAppSummary,
  useNewDevices,
  usePatchAdoption,
  usePatchInstalls,
  useReleases,
  useUniqueUsers,
  useVersionDistribution,
} from '../../api/hooks'
import { mergeSeries, ShareBars, TimeChart } from '../../components/charts'
import { PlatformBadge } from '../../components/platform'
import { Badge, Card, CardHeader, Code, Empty, Loading, Stat } from '../../components/ui'
import { compact, num, timeAgo } from '../../lib/format'
import { PeriodPicker, useAppCtx } from './AppLayout'

export function OverviewPage() {
  const { app, range } = useAppCtx()
  const appId = app.app_id
  const { data: summary } = useAppSummary(appId)
  const { data: users } = useUniqueUsers(appId, range)
  const { data: installs } = usePatchInstalls(appId, range)
  const { data: versions } = useVersionDistribution(appId)
  const { data: fresh } = useNewDevices(appId)
  const { data: releases } = useReleases(appId)
  const latest = releases?.at(-1)
  const { data: adoption } = usePatchAdoption(appId, latest?.version, range)

  if (summary && summary.releases === 0) return <GettingStarted />

  const installSeries = mergeSeries(
    (installs?.current.breakdown ?? []).slice(0, 5).map((b) => ({
      key: b.group_value,
      points: (b.time_series ?? []).map((p) => ({ period: p.period, value: p.count })),
    })),
  )

  return (
    <div className="space-y-6">
      <div className="flex justify-end">
        <PeriodPicker />
      </div>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat
          label="Active installs"
          icon={<Users className="size-4" />}
          value={users ? compact(users.current.unique_users) : '—'}
          current={users?.current.unique_users}
          previous={users?.previous?.unique_users}
          hint="vs. previous period"
        />
        <Stat
          label="Patch installs"
          icon={<Download className="size-4" />}
          value={installs ? compact(installs.current.count) : '—'}
          current={installs?.current.count}
          previous={installs?.previous?.count}
          hint="vs. previous period"
        />
        <Stat
          label="New installs"
          icon={<Smartphone className="size-4" />}
          value={fresh ? compact(fresh.current) : '—'}
          current={fresh?.current}
          previous={fresh?.previous}
          hint="last 30 days"
        />
        <Stat
          label="Failures"
          icon={<AlertTriangle className="size-4" />}
          value={summary ? num(summary.failures_30d) : '—'}
          hint={
            summary?.failures_30d ? (
              <Link to="events" className="text-danger hover:underline">
                See device events
              </Link>
            ) : (
              'last 30 days'
            )
          }
        />
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title="Active installs" description="Unique installs that checked for updates" />
          <div className="p-4">
            {users ? (
              users.current.unique_users === 0 ? (
                <Empty title="No device activity yet">Installs appear once a release checks for patches.</Empty>
              ) : (
                <TimeChart
                  granularity={range.granularity}
                  series={[{ key: 'users', label: 'Installs' }]}
                  data={(users.current.time_series ?? []).map((p) => ({ period: p.period, users: p.unique_users }))}
                />
              )
            ) : (
              <Loading />
            )}
          </div>
        </Card>
        <Card>
          <CardHeader title="Release versions" description="Installs seen in the last 30 days" />
          <div className="p-5">
            {versions?.entries.length ? (
              <ShareBars
                rows={versions.entries.slice(0, 6).map((e) => ({
                  label: e.release_version ?? 'unknown',
                  value: e.device_count,
                  pct: e.percentage,
                }))}
              />
            ) : (
              <Empty title="No installs yet" />
            )}
          </div>
        </Card>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Patch installs" description="By release" />
          <div className="p-4">
            {installs?.current.count ? (
              <TimeChart
                kind="bar"
                stacked
                granularity={range.granularity}
                series={(installs.current.breakdown ?? []).slice(0, 5).map((b) => ({ key: b.group_value, label: b.group_value }))}
                data={installSeries}
              />
            ) : (
              <Empty title="No patch installs in this period" />
            )}
          </div>
        </Card>
        <Card>
          <CardHeader
            title="Patch adoption"
            description={latest ? `Share of ${latest.version} installs on each patch` : 'Latest release'}
          />
          <div className="p-4">
            {adoption?.patches.length ? (
              <TimeChart
                kind="line"
                percent
                granularity={range.granularity}
                series={adoption.patches.map((p) => ({ key: `p${p.patch_number}`, label: `Patch ${p.patch_number}` }))}
                data={mergeSeries(
                  adoption.patches.map((p) => ({
                    key: `p${p.patch_number}`,
                    points: p.series.filter((s) => s.period).map((s) => ({ period: s.period!, value: s.adoption_pct })),
                  })),
                )}
              />
            ) : (
              <Empty title="No patches for the latest release" />
            )}
          </div>
        </Card>
      </div>

      <Card>
        <CardHeader
          title="Recent releases"
          actions={
            <Link to="releases" className="text-[13px] font-medium text-accent hover:underline">
              View all
            </Link>
          }
        />
        <div className="divide-y divide-line">
          {(releases ?? [])
            .slice(-5)
            .reverse()
            .map((r) => (
              <Link key={r.id} to={`releases/${r.id}`} className="flex items-center gap-4 px-5 py-3 hover:bg-panel-2">
                <Rocket className="size-4 text-faint" />
                <span className="font-mono text-sm font-medium">{r.version}</span>
                <div className="flex gap-1.5">
                  {Object.entries(r.platforms).map(([p, d]) => (
                    <span key={p} className="flex items-center gap-1">
                      <PlatformBadge platform={p} />
                      {d.status === 'draft' && <Badge tone="warn">draft</Badge>}
                    </span>
                  ))}
                </div>
                <span className="ml-auto text-[12px] text-faint">{timeAgo(r.created_at)}</span>
              </Link>
            ))}
        </div>
      </Card>
      {summary && (
        <p className="flex items-center gap-2 text-[12px] text-faint">
          <Layers className="size-3.5" />
          {num(summary.releases)} releases · {num(summary.patches)} patches · {num(summary.channels)} channels ·{' '}
          {num(summary.active_devices_24h)} installs active in the last 24 hours
        </p>
      )}
    </div>
  )
}

function GettingStarted() {
  const { app } = useAppCtx()
  const base = window.location.origin
  return (
    <Card>
      <CardHeader title="Ship your first release" description="Point the Shorebird CLI at this server, release, then patch." />
      <div className="grid gap-6 p-5 lg:grid-cols-3">
        {[
          { n: 1, title: 'Configure', body: 'Add to shorebird.yaml in your Flutter project:', code: `app_id: ${app.app_id}\nbase_url: ${base}` },
          { n: 2, title: 'Authenticate', body: 'Create a key under API keys, then:', code: 'export SHOREBIRD_TOKEN=sb_api_…' },
          { n: 3, title: 'Release', body: 'Build and publish a release. Ship it to the stores.', code: 'shorebird release android\nshorebird release ios' },
        ].map((s) => (
          <div key={s.n}>
            <div className="mb-2 flex items-center gap-2">
              <span className="flex size-6 items-center justify-center rounded-full bg-accent-soft text-[12px] font-semibold text-accent">{s.n}</span>
              <span className="font-medium">{s.title}</span>
            </div>
            <p className="mb-2 text-[13px] text-muted">{s.body}</p>
            <Code copy>{s.code}</Code>
          </div>
        ))}
      </div>
    </Card>
  )
}

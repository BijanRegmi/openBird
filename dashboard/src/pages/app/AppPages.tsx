import clsx from 'clsx'
import { CheckCircle2, Clock, GitBranch, Hammer, Plus, Radio, ShieldCheck, Trash2, XCircle } from 'lucide-react'
import { Fragment, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQueries } from '@tanstack/react-query'
import { api, v1, type ReleasePatch, type S } from '../../api/client'
import {
  useActiveHours,
  useBuildRuns,
  useChannels,
  useConfig,
  useCreateChannel,
  useDeleteApp,
  useDeleteChannel,
  useEvents,
  useHeatmap,
  useReleases,
  useRenameApp,
  useSigningKey,
  useUniqueUsers,
} from '../../api/hooks'
import { chartColors, mergeSeries, TimeChart } from '../../components/charts'
import { PlatformBadge } from '../../components/platform'
import {
  Badge,
  Button,
  Card,
  CardHeader,
  Code,
  Confirm,
  Empty,
  ErrorNote,
  Input,
  Loading,
  Modal,
  Segmented,
  Table,
  Td,
} from '../../components/ui'
import { dateTime, duration, eventLabel, num, platformLabel, timeAgo } from '../../lib/format'
import { useOrg } from '../../lib/org'
import { PeriodPicker, useAppCtx } from './AppLayout'

// Channels

export function ChannelsPage() {
  const { app } = useAppCtx()
  const { canWrite } = useOrg()
  const { data: channels, isLoading } = useChannels(app.app_id)
  const { data: releases } = useReleases(app.app_id)
  const recent = (releases ?? []).slice(-6)
  // What each channel serves: the newest patch of each recent release on it.
  const patchQueries = useQueries({
    queries: recent.map((r) => ({
      queryKey: ['app', app.app_id, 'release', r.id, 'patches'],
      queryFn: () =>
        api.get<S['GetReleasePatchesResponse']>(v1(`/apps/${app.app_id}/releases/${r.id}/patches`)).then((x) => x.patches as ReleasePatch[]),
    })),
  })
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [deleting, setDeleting] = useState<{ id: number; name: string } | null>(null)
  const create = useCreateChannel(app.app_id)
  const del = useDeleteChannel(app.app_id)
  if (isLoading) return <Loading />
  return (
    <>
      <Card>
        <CardHeader
          title="Channels"
          description={
            <>
              Devices check the channel in their <code className="font-mono">shorebird.yaml</code> (<code className="font-mono">stable</code> by
              default). Use others for QA or beta testers.
            </>
          }
          actions={
            canWrite && (
              <Button icon={<Plus className="size-4" />} onClick={() => setCreating(true)}>
                New channel
              </Button>
            )
          }
        />
        <div className="divide-y divide-line">
          {channels?.map((c) => (
            <div key={c.id} className="flex flex-wrap items-center gap-4 px-5 py-4">
              <div className="flex w-40 items-center gap-2">
                <Radio className="size-4 text-accent" />
                <span className="font-medium">{c.name}</span>
              </div>
              <div className="flex min-w-0 flex-1 flex-wrap gap-2">
                {recent
                  .map((r, i) => {
                    const live = (patchQueries[i]?.data ?? [])
                      .filter((p) => p.channel === c.name && !p.is_rolled_back)
                      .sort((a, b) => b.number - a.number)[0]
                    return live ? (
                      <span key={r.id} className="inline-flex items-center gap-1.5 rounded-md border border-line px-2 py-1 text-[12px]">
                        <span className="font-mono">{r.version}</span>
                        <span className="text-faint">→</span>
                        <span className="font-medium">#{live.number}</span>
                        {(live.rollout_percentage ?? 100) < 100 && <Badge tone="warn">{live.rollout_percentage}%</Badge>}
                      </span>
                    ) : null
                  })
                  .filter(Boolean)
                  .reverse()}
                {recent.every((_, i) => !(patchQueries[i]?.data ?? []).some((p) => p.channel === c.name)) && (
                  <span className="text-[13px] text-faint">No patches on this channel</span>
                )}
              </div>
              {canWrite && c.name !== 'stable' && (
                <Button variant="ghost" size="sm" icon={<Trash2 className="size-4" />} onClick={() => setDeleting(c)}>
                  Delete
                </Button>
              )}
            </div>
          ))}
        </div>
      </Card>
      <Card className="mt-6 p-5">
        <p className="mb-2 text-sm font-medium">Point a build at a channel</p>
        <Code copy>{`# shorebird.yaml\nchannel: beta`}</Code>
        <p className="mt-3 mb-2 text-sm font-medium">Publish a patch to it</p>
        <Code copy>{`shorebird patch android --track=beta`}</Code>
      </Card>
      <Modal
        open={creating}
        onClose={() => setCreating(false)}
        title="New channel"
        footer={
          <Button
            variant="primary"
            loading={create.isPending}
            disabled={!name.trim()}
            onClick={() => create.mutate(name.trim(), { onSuccess: () => (setCreating(false), setName('')) })}
          >
            Create
          </Button>
        }
      >
        <Input autoFocus label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="beta" className="font-mono" />
      </Modal>
      <Confirm
        open={!!deleting}
        onClose={() => setDeleting(null)}
        title={`Delete channel ${deleting?.name}?`}
        description="Its patches stay but are on no channel, so devices on it stop getting updates."
        action="Delete channel"
        loading={del.isPending}
        onConfirm={() => del.mutate(deleting!.id, { onSuccess: () => setDeleting(null) })}
      />
    </>
  )
}

// Insights

const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

export function InsightsPage() {
  const { app, range } = useAppCtx()
  const [groupBy, setGroupBy] = useState<'platform' | 'release_version'>('platform')
  const { data: users } = useUniqueUsers(app.app_id, range, groupBy)
  const { data: hours } = useActiveHours(app.app_id)
  const { data: heat } = useHeatmap(app.app_id)
  const breakdown = users?.current.breakdown ?? []
  const max = Math.max(1, ...(heat?.cells ?? []).map((c) => c.average_active_devices))
  const cell = (d: number, h: number) =>
    heat?.cells.find((c) => c.day_of_week_utc === d && c.hour_utc === h)?.average_active_devices ?? 0
  const offset = -new Date().getTimezoneOffset() / 60
  return (
    <div className="space-y-6">
      <div className="flex justify-end">
        <PeriodPicker />
      </div>
      <Card>
        <CardHeader
          title="Active installs"
          description="Unique installs by group"
          actions={
            <Segmented<'platform' | 'release_version'>
              value={groupBy}
              onChange={setGroupBy}
              options={[
                { value: 'platform', label: 'Platform' },
                { value: 'release_version', label: 'Release' },
              ]}
            />
          }
        />
        <div className="grid gap-6 p-4 lg:grid-cols-4">
          <div className="lg:col-span-3">
            {breakdown.length ? (
              <TimeChart
                stacked
                granularity={range.granularity}
                series={breakdown.slice(0, 5).map((b) => ({
                  key: b.group_value,
                  label: groupBy === 'platform' ? (platformLabel[b.group_value] ?? b.group_value) : b.group_value,
                }))}
                data={mergeSeries(
                  breakdown.slice(0, 5).map((b) => ({
                    key: b.group_value,
                    points: (b.time_series ?? []).map((p) => ({ period: p.period, value: p.unique_users })),
                  })),
                )}
              />
            ) : (
              <Empty title="No activity in this period" />
            )}
          </div>
          <div className="space-y-2">
            {breakdown.map((b, i) => (
              <div key={b.group_value} className="flex items-center gap-2 text-[13px]">
                <span className="size-2.5 rounded-full" style={{ background: chartColors[i % 5] }} />
                <span className="truncate font-mono">{groupBy === 'platform' ? (platformLabel[b.group_value] ?? b.group_value) : b.group_value}</span>
                <span className="ml-auto tabular-nums text-muted">{num(b.unique_users)}</span>
              </div>
            ))}
          </div>
        </div>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader
            title="Active hours"
            description={`Average installs active per hour (UTC), last ${hours?.lookback_days ?? 14} days`}
          />
          <div className="p-4">
            {hours && hours.busiest_hour_utc !== null ? (
              <>
                <TimeChart
                  kind="bar"
                  granularity="hour"
                  height={200}
                  xFormat={(iso) => `${new Date(iso).getUTCHours()}:00`}
                  series={[{ key: 'v', label: 'Installs' }]}
                  data={hours.hourly.map((h) => ({
                    period: new Date(Date.UTC(2000, 0, 1, h.hour_utc)).toISOString(),
                    v: Number(h.average_active_devices.toFixed(2)),
                  }))}
                />
                {hours.recommended_window_start_utc !== null && (
                  <p className="mt-3 rounded-lg bg-accent-soft px-3 py-2 text-[13px] text-accent">
                    Quietest window: {hours.recommended_window_start_utc}:00–
                    {(hours.recommended_window_start_utc + hours.recommended_window_length_hours) % 24}:00 UTC. A good time to start
                    a risky rollout.
                  </p>
                )}
              </>
            ) : (
              <Empty title="Not enough activity yet" />
            )}
          </div>
        </Card>
        <Card>
          <CardHeader title="Weekly activity" description={`UTC (you're UTC${offset >= 0 ? '+' : ''}${offset})`} />
          <div className="overflow-x-auto p-4">
            {heat?.cells.length ? (
              <div className="inline-grid min-w-full gap-[3px]" style={{ gridTemplateColumns: 'auto repeat(24, minmax(10px, 1fr))' }}>
                <span />
                {Array.from({ length: 24 }, (_, h) => (
                  <span key={h} className="text-center text-[9px] text-faint">
                    {h % 6 === 0 ? h : ''}
                  </span>
                ))}
                {days.map((d, di) => (
                  <Fragment key={d}>
                    <span className="pr-2 text-[11px] text-faint">
                      {d}
                    </span>
                    {Array.from({ length: 24 }, (_, h) => {
                      const v = cell(di, h)
                      return (
                        <span
                          key={`${d}${h}`}
                          title={`${d} ${h}:00 UTC · ${v.toFixed(1)} installs`}
                          className="aspect-square rounded-[3px]"
                          style={{ background: v ? `color-mix(in oklab, var(--accent) ${15 + (v / max) * 85}%, transparent)` : 'var(--panel-2)' }}
                        />
                      )
                    })}
                  </Fragment>
                ))}
              </div>
            ) : (
              <Empty title="Not enough activity yet" />
            )}
          </div>
        </Card>
      </div>
      <DownloadsFunnel />
    </div>
  )
}

function DownloadsFunnel() {
  const { app, range } = useAppCtx()
  const { data: events } = useEvents(app.app_id)
  const counts = useMemo(() => {
    const out: Record<string, number> = {}
    for (const e of events ?? []) {
      if (new Date(e.occurred_at) >= new Date(range.start)) out[e.type] = (out[e.type] ?? 0) + 1
    }
    return out
  }, [events, range.start])
  const steps = [
    { key: '__patch_download__', label: 'Downloaded' },
    { key: '__patch_install__', label: 'Installed' },
    { key: '__patch_install_failure__', label: 'Install failed' },
    { key: '__patch_update_failure__', label: 'Update failed' },
  ]
  const top = Math.max(1, ...steps.map((s) => counts[s.key] ?? 0))
  return (
    <Card>
      <CardHeader title="Update outcomes" description="From the latest 300 device events in this period" />
      <div className="grid gap-4 p-5 sm:grid-cols-4">
        {steps.map((s, i) => (
          <div key={s.key}>
            <div className="text-[13px] text-muted">{s.label}</div>
            <div className="mt-1 text-xl font-semibold tabular-nums">{num(counts[s.key])}</div>
            <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-panel-2">
              <div
                className="h-full rounded-full"
                style={{ width: `${((counts[s.key] ?? 0) / top) * 100}%`, background: i >= 2 ? 'var(--danger)' : chartColors[i] }}
              />
            </div>
          </div>
        ))}
      </div>
    </Card>
  )
}

// Device events

export function EventsPage() {
  const { app } = useAppCtx()
  const [type, setType] = useState<string>('')
  const { data: events, isLoading, error } = useEvents(app.app_id, type || undefined)
  if (error) return <ErrorNote error={error} />
  return (
    <Card>
      <CardHeader
        title="Device events"
        description="What updaters report, newest first. Refreshes every 15 seconds."
        actions={
          <Segmented
            value={type}
            onChange={setType}
            options={[
              { value: '', label: 'All' },
              { value: '__patch_install__', label: 'Installs' },
              { value: '__patch_download__', label: 'Downloads' },
              { value: '__patch_install_failure__', label: 'Failures' },
            ]}
          />
        }
      />
      {isLoading ? (
        <Loading />
      ) : !events?.length ? (
        <Empty icon={<Radio className="size-6" />} title="No events yet">
          Devices report downloads, installs and failures as they update.
        </Empty>
      ) : (
        <Table head={['Event', 'Release', 'Patch', 'Device', 'Platform', 'When']}>
          {events.map((e) => {
            const failed = e.type.includes('failure')
            return (
              <tr key={e.id}>
                <Td>
                  <div className="flex items-center gap-2">
                    {failed ? <XCircle className="size-4 text-danger" /> : <CheckCircle2 className="size-4 text-ok" />}
                    <span className={clsx('font-medium', failed && 'text-danger')}>{eventLabel[e.type] ?? e.type}</span>
                  </div>
                  {(e.failure_category || e.message) && (
                    <div className="mt-0.5 max-w-md truncate text-[12px] text-faint" title={e.message ?? ''}>
                      {e.failure_category && <Badge tone="danger">{e.failure_category}</Badge>} {e.message}
                    </div>
                  )}
                </Td>
                <Td className="font-mono text-[13px]">{e.release_version}</Td>
                <Td>#{e.patch_number}</Td>
                <Td className="font-mono text-[12px] text-faint">{e.client}…</Td>
                <Td>
                  <span className="flex items-center gap-1.5">
                    <PlatformBadge platform={e.platform} />
                    <span className="font-mono text-[12px] text-faint">{e.arch}</span>
                  </span>
                </Td>
                <Td className="text-[13px] whitespace-nowrap text-muted" >
                  <span title={dateTime(e.occurred_at)}>{timeAgo(e.occurred_at)}</span>
                </Td>
              </tr>
            )
          })}
        </Table>
      )}
    </Card>
  )
}

// Build history

export function BuildsPage() {
  const { app } = useAppCtx()
  const { data: runs, isLoading } = useBuildRuns(app.app_id)
  const { data: releases } = useReleases(app.app_id)
  const version = (id?: number | null) => releases?.find((r) => r.id === id)?.version
  const [open, setOpen] = useState<number | null>(null)
  return (
    <Card>
      <CardHeader title="Build history" description="Every shorebird release and patch run against this app" />
      {isLoading ? (
        <Loading />
      ) : !runs?.length ? (
        <Empty icon={<Hammer className="size-6" />} title="No builds recorded yet" />
      ) : (
        <div className="divide-y divide-line">
          {runs.map((r) => (
            <div key={r.id}>
              <button onClick={() => setOpen(open === r.id ? null : r.id)} className="flex w-full flex-wrap items-center gap-3 px-5 py-3 text-left hover:bg-panel-2">
                {r.outcome === 'succeeded' ? <CheckCircle2 className="size-4 text-ok" /> : <XCircle className="size-4 text-danger" />}
                <span className="font-medium capitalize">{r.command}</span>
                <PlatformBadge platform={r.platform} />
                {version(r.release_id) && <span className="font-mono text-[13px] text-muted">{version(r.release_id)}</span>}
                {r.dry_run && <Badge>dry run</Badge>}
                {r.reason && <Badge tone="danger">{r.reason.replaceAll('_', ' ')}</Badge>}
                <span className="ml-auto flex items-center gap-1 text-[12px] text-faint">
                  <Clock className="size-3.5" /> {duration(r.duration_ms)} · {timeAgo(r.created_at)}
                </span>
              </button>
              {open === r.id && (
                <div className="grid gap-4 bg-panel-2/50 px-5 py-4 text-[13px] sm:grid-cols-2">
                  <div>
                    <div className="mb-1 text-faint">Run</div>
                    <div className="font-mono">{r.run_id}</div>
                    <div className="mt-3 mb-1 text-faint">Started</div>
                    <div>{dateTime(r.started_at)}</div>
                    {r.build_flags && (
                      <>
                        <div className="mt-3 mb-1 text-faint">Build flags</div>
                        <div>
                          {r.build_flags.dart_define_count} dart-defines{r.build_flags.target ? ` · target ${r.build_flags.target}` : ''}
                        </div>
                      </>
                    )}
                  </div>
                  {r.metadata && (
                    <div>
                      <div className="mb-1 text-faint">Environment</div>
                      <Code>{JSON.stringify(r.metadata, null, 2)}</Code>
                    </div>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </Card>
  )
}

// Settings

export function AppSettingsPage() {
  const { app } = useAppCtx()
  const { isAdmin, canWrite } = useOrg()
  const { data: config } = useConfig()
  const [name, setName] = useState(app.display_name)
  const rename = useRenameApp(app.app_id)
  const del = useDeleteApp(app.app_id)
  const [deleting, setDeleting] = useState(false)
  const [showKey, setShowKey] = useState(false)
  const { data: key, isFetching } = useSigningKey(app.app_id, showKey)
  const navigate = useNavigate()
  const base = config?.api_base_url ?? window.location.origin
  return (
    <div className="space-y-6">
      <Card>
        <CardHeader title="General" />
        <div className="flex flex-wrap items-end gap-3 p-5">
          <div className="min-w-64 flex-1">
            <Input label="App name" value={name} onChange={(e) => setName(e.target.value)} disabled={!canWrite} />
          </div>
          <Button
            variant="primary"
            disabled={!canWrite || !name.trim() || name === app.display_name}
            loading={rename.isPending}
            onClick={() => rename.mutate({ name: name.trim() })}
          >
            Save
          </Button>
        </div>
      </Card>
      <Card>
        <CardHeader title="Configuration" description="What your Flutter project's shorebird.yaml needs for this server" />
        <div className="p-5">
          <Code copy>{`app_id: ${app.app_id}\nbase_url: ${base}\n# channel: stable\n# auto_update: true`}</Code>
          <p className="mt-3 text-[13px] text-muted">
            <GitBranch className="mr-1 inline size-3.5" />
            <code className="font-mono">base_url</code> is built into every release, so keep it stable (use a domain you control).
          </p>
        </div>
      </Card>
      <Card>
        <CardHeader
          title="Patch signing"
          description="Releases embed your organization's public key; the server signs every patch, and devices reject anything unsigned."
          actions={
            !showKey && (
              <Button size="sm" icon={<ShieldCheck className="size-4" />} onClick={() => setShowKey(true)} disabled={!canWrite}>
                Show public key
              </Button>
            )
          }
        />
        {showKey && <div className="p-5">{isFetching || !key ? <Loading /> : <Code copy>{key.public_key_pem.trim()}</Code>}</div>}
      </Card>
      {isAdmin && (
        <Card className="border-danger/40">
          <CardHeader title={<span className="text-danger">Danger zone</span>} />
          <div className="flex flex-wrap items-center justify-between gap-4 p-5">
            <div>
              <p className="font-medium">Delete this app</p>
              <p className="text-[13px] text-muted">Deletes every release, patch and artifact. Installed apps stop receiving patches.</p>
            </div>
            <Button variant="danger" icon={<Trash2 className="size-4" />} onClick={() => setDeleting(true)}>
              Delete app
            </Button>
          </div>
        </Card>
      )}
      <Confirm
        open={deleting}
        onClose={() => setDeleting(false)}
        title={`Delete ${app.display_name}?`}
        description="This can't be undone."
        action="Delete app"
        confirmText={app.display_name}
        loading={del.isPending}
        onConfirm={() => del.mutate(undefined, { onSuccess: () => navigate('/apps') })}
      />
    </div>
  )
}

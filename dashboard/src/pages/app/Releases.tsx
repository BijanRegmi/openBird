import clsx from 'clsx'
import {
  ArrowUpRight,
  Download,
  FileText,
  MoreHorizontal,
  Pencil,
  Rocket,
  RotateCcw,
  Search,
  ShieldCheck,
  ShieldOff,
  Trash2,
  Undo2,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import type { ReleasePatch } from '../../api/client'
import {
  useChannels,
  useDeleteRelease,
  usePatchAdoption,
  usePatches,
  usePatchInstalls,
  usePromotePatch,
  useRelease,
  useReleaseArtifacts,
  useReleases,
  useRollback,
  useSetRollout,
  useUpdatePatchNotes,
  useUpdateRelease,
} from '../../api/hooks'
import { mergeSeries, TimeChart } from '../../components/charts'
import { PlatformBadge } from '../../components/platform'
import {
  Badge,
  Button,
  Card,
  CardHeader,
  Code,
  Confirm,
  CopyButton,
  Empty,
  ErrorNote,
  Loading,
  Menu,
  Modal,
  Select,
  Table,
  Td,
} from '../../components/ui'
import { bytes, dateTime, num, timeAgo } from '../../lib/format'
import { useOrg } from '../../lib/org'
import { PeriodPicker, useAppCtx } from './AppLayout'

export function ReleasesPage() {
  const { app } = useAppCtx()
  const { data: releases, isLoading, error } = useReleases(app.app_id)
  const [q, setQ] = useState('')
  const list = useMemo(
    () => [...(releases ?? [])].reverse().filter((r) => r.version.toLowerCase().includes(q.toLowerCase())),
    [releases, q],
  )
  if (error) return <ErrorNote error={error} />
  if (isLoading) return <Loading />
  if (!releases?.length)
    return (
      <Card>
        <Empty icon={<Rocket className="size-6" />} title="No releases yet">
          Run <code className="font-mono">shorebird release android</code> (or ios) in your project.
        </Empty>
      </Card>
    )
  return (
    <Card>
      <CardHeader
        title="Releases"
        description="Each store build you can patch"
        actions={
          <div className="relative">
            <Search className="pointer-events-none absolute top-2 left-2.5 size-4 text-faint" />
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Filter versions"
              className="h-8 w-48 rounded-lg border border-line bg-panel pr-2 pl-8 text-[13px] focus:border-accent focus:outline-none"
            />
          </div>
        }
      />
      <Table head={['Version', 'Platforms', 'Flutter', 'Created', '']}>
        {list.map((r) => (
          <tr key={r.id} className="hover:bg-panel-2">
            <Td>
              <Link to={String(r.id)} className="font-mono font-medium hover:text-accent">
                {r.version}
              </Link>
              {r.display_name && <div className="text-[12px] text-faint">{r.display_name}</div>}
            </Td>
            <Td>
              <div className="flex flex-wrap gap-1.5">
                {Object.entries(r.platforms).map(([p, d]) => (
                  <span key={p} className="flex items-center gap-1">
                    <PlatformBadge platform={p} />
                    {d.status === 'draft' && <Badge tone="warn">draft</Badge>}
                  </span>
                ))}
              </div>
            </Td>
            <Td className="text-[13px] text-muted">{r.flutter_version ?? r.flutter_revision.slice(0, 10)}</Td>
            <Td className="text-[13px] text-muted">{timeAgo(r.created_at)}</Td>
            <Td className="text-right">
              <Link to={String(r.id)} className="inline-flex items-center gap-1 text-[13px] font-medium text-accent hover:underline">
                Open <ArrowUpRight className="size-3.5" />
              </Link>
            </Td>
          </tr>
        ))}
      </Table>
    </Card>
  )
}

export function ReleaseDetailPage() {
  const { app, range } = useAppCtx()
  const appId = app.app_id
  const releaseId = Number(useParams().releaseId)
  const { canWrite } = useOrg()
  const { data: release, error } = useRelease(appId, releaseId)
  const { data: patches } = usePatches(appId, releaseId)
  const { data: artifacts } = useReleaseArtifacts(appId, releaseId)
  const { data: installs } = usePatchInstalls(appId, range, releaseId)
  const { data: adoption } = usePatchAdoption(appId, release?.version, range)
  const [editingNotes, setEditingNotes] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const del = useDeleteRelease(appId)
  const navigate = useNavigate()
  if (error) return <ErrorNote error={error} />
  if (!release) return <Loading />
  const installsByPatch = new Map((installs?.current.breakdown ?? []).map((b) => [b.group_value, b.count]))
  const managed = artifacts?.find((a) => a.signing?.mode === 'managed')

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Link to=".." relative="path" className="text-[13px] text-muted hover:text-fg">
            Releases /
          </Link>
          <h2 className="mt-1 font-mono text-2xl font-semibold tracking-tight">{release.version}</h2>
          <div className="mt-2 flex flex-wrap items-center gap-2 text-[13px] text-muted">
            {Object.entries(release.platforms).map(([p, d]) => (
              <span key={p} className="flex items-center gap-1">
                <PlatformBadge platform={p} />
                <Badge tone={d.status === 'active' ? 'ok' : 'warn'}>{d.status}</Badge>
                {d.signing_mode && (
                  <Badge tone={d.signing_mode === 'unsigned' ? 'warn' : 'accent'}>
                    {d.signing_mode === 'unsigned' ? <ShieldOff className="size-3" /> : <ShieldCheck className="size-3" />}
                    {d.signing_mode}
                  </Badge>
                )}
              </span>
            ))}
            <span>· Flutter {release.flutter_version ?? release.flutter_revision.slice(0, 10)}</span>
            <span>· {dateTime(release.created_at)}</span>
          </div>
        </div>
        {canWrite && (
          <div className="flex gap-2">
            <Button icon={<Pencil className="size-4" />} onClick={() => setEditingNotes(true)}>
              Notes
            </Button>
            <Button variant="ghost" className="text-danger" icon={<Trash2 className="size-4" />} onClick={() => setDeleting(true)}>
              Delete
            </Button>
          </div>
        )}
      </div>
      {release.notes && (
        <Card className="flex gap-3 p-4 text-sm">
          <FileText className="mt-0.5 size-4 shrink-0 text-faint" />
          <p className="whitespace-pre-wrap text-muted">{release.notes}</p>
        </Card>
      )}

      <Card>
        <CardHeader
          title="Patches"
          description="Newest first. Devices on a channel get its newest patch that's rolled out to them."
        />
        {!patches ? (
          <Loading />
        ) : patches.length === 0 ? (
          <Empty icon={<Rocket className="size-6" />} title="No patches yet">
            <Code copy>{`shorebird patch ${Object.keys(release.platforms)[0] ?? 'android'} --release-version ${release.version}`}</Code>
          </Empty>
        ) : (
          <Table head={['Patch', 'Channel', 'Rollout', 'Installs', 'Artifacts', 'Created', '']}>
            {[...patches].reverse().map((p) => (
              <PatchRow key={p.id} patch={p} releaseId={releaseId} installs={installsByPatch.get(String(p.number)) ?? 0} />
            ))}
          </Table>
        )}
      </Card>

      <div className="flex justify-end">
        <PeriodPicker />
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Patch installs" description="By patch" />
          <div className="p-4">
            {installs?.current.count ? (
              <TimeChart
                kind="bar"
                stacked
                granularity={range.granularity}
                series={(installs.current.breakdown ?? []).map((b) => ({ key: `p${b.group_value}`, label: `Patch ${b.group_value}` }))}
                data={mergeSeries(
                  (installs.current.breakdown ?? []).map((b) => ({
                    key: `p${b.group_value}`,
                    points: (b.time_series ?? []).map((t) => ({ period: t.period, value: t.count })),
                  })),
                )}
              />
            ) : (
              <Empty title="No installs in this period" />
            )}
          </div>
        </Card>
        <Card>
          <CardHeader title="Adoption" description="Share of this release's active installs on each patch" />
          <div className="p-4">
            {adoption?.patches.some((p) => p.series.length) ? (
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
              <Empty title="No device activity for this release yet" />
            )}
          </div>
        </Card>
      </div>

      <Card>
        <CardHeader title="Artifacts" description="What `shorebird release` uploaded. Links expire after a day." />
        {!artifacts ? (
          <Loading />
        ) : (
          <Table head={['Platform', 'Arch', 'Size', 'SHA-256', 'Signing', '']}>
            {artifacts.map((a) => (
              <tr key={a.id}>
                <Td>
                  <PlatformBadge platform={a.platform} />
                </Td>
                <Td className="font-mono text-[13px]">{a.arch}</Td>
                <Td className="text-[13px] text-muted">{bytes(a.size)}</Td>
                <Td>
                  <span className="font-mono text-[12px] text-faint">{a.hash.slice(0, 16)}…</span>
                  <CopyButton value={a.hash} />
                </Td>
                <Td>{a.signing ? <Badge tone={a.signing.mode === 'unsigned' ? 'warn' : 'accent'}>{a.signing.mode}</Badge> : <Badge>—</Badge>}</Td>
                <Td className="text-right">
                  <a href={a.url} className="inline-flex items-center gap-1 text-[13px] font-medium text-accent hover:underline">
                    <Download className="size-3.5" /> Download
                  </a>
                </Td>
              </tr>
            ))}
          </Table>
        )}
        {managed?.signing?.public_key_pem && (
          <details className="border-t border-line px-5 py-3 text-[13px]">
            <summary className="cursor-pointer text-muted">Managed public key embedded in this release (key #{managed.signing.key_id})</summary>
            <div className="mt-3">
              <Code copy>{managed.signing.public_key_pem.trim()}</Code>
            </div>
          </details>
        )}
      </Card>

      <NotesModal open={editingNotes} onClose={() => setEditingNotes(false)} releaseId={releaseId} initial={release.notes ?? ''} />
      <Confirm
        open={deleting}
        onClose={() => setDeleting(false)}
        title={`Delete release ${release.version}?`}
        description="Its artifacts and every patch are deleted. Installed apps keep running the release but receive no more patches."
        action="Delete release"
        confirmText={release.version}
        loading={del.isPending}
        onConfirm={() => del.mutate(releaseId, { onSuccess: () => navigate(`/apps/${appId}/releases`) })}
      />
    </div>
  )
}

function NotesModal({ open, onClose, releaseId, initial }: { open: boolean; onClose: () => void; releaseId: number; initial: string }) {
  const { app } = useAppCtx()
  const update = useUpdateRelease(app.app_id, releaseId)
  const [notes, setNotes] = useState(initial)
  useEffect(() => setNotes(initial), [initial, open])
  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Release notes"
      footer={
        <Button variant="primary" loading={update.isPending} onClick={() => update.mutate({ notes }, { onSuccess: onClose })}>
          Save
        </Button>
      }
    >
      <textarea
        value={notes}
        onChange={(e) => setNotes(e.target.value)}
        rows={6}
        className="w-full rounded-lg border border-line bg-panel p-3 text-sm focus:border-accent focus:outline-none"
        placeholder="What shipped in this build"
      />
    </Modal>
  )
}

function RolloutBar({ pct }: { pct: number }) {
  return (
    <div className="flex items-center gap-2">
      <div className="h-1.5 w-20 overflow-hidden rounded-full bg-panel-2">
        <div className="h-full rounded-full bg-accent" style={{ width: `${pct}%` }} />
      </div>
      <span className="text-[13px] tabular-nums">{pct}%</span>
    </div>
  )
}

function PatchRow({ patch, releaseId, installs }: { patch: ReleasePatch; releaseId: number; installs: number }) {
  const { app } = useAppCtx()
  const { canWrite } = useOrg()
  const [dialog, setDialog] = useState<'promote' | 'rollout' | 'rollback' | 'notes' | null>(null)
  const rollback = useRollback(app.app_id, releaseId)
  const archs = [...new Set(patch.artifacts.map((a) => a.arch))]
  const platforms = [...new Set(patch.artifacts.map((a) => a.platform))]
  const item = 'flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left text-[13px] hover:bg-panel-2'
  return (
    <tr className={clsx('hover:bg-panel-2/60', patch.is_rolled_back && 'opacity-70')}>
      <Td>
        <div className="flex items-center gap-2">
          <span className="font-semibold">#{patch.number}</span>
          {patch.is_rolled_back && <Badge tone="danger">rolled back</Badge>}
        </div>
        {patch.notes && <div className="mt-0.5 max-w-56 truncate text-[12px] text-faint">{patch.notes}</div>}
      </Td>
      <Td>{patch.channel ? <Badge tone="accent">{patch.channel}</Badge> : <Badge>unpromoted</Badge>}</Td>
      <Td>{patch.channel ? <RolloutBar pct={patch.rollout_percentage ?? 100} /> : <span className="text-faint">—</span>}</Td>
      <Td className="tabular-nums">{num(installs)}</Td>
      <Td>
        <div className="flex flex-wrap items-center gap-1">
          {platforms.map((p) => (
            <PlatformBadge key={p} platform={p} />
          ))}
          <span className="font-mono text-[12px] text-faint">{archs.join(', ')}</span>
        </div>
      </Td>
      <Td className="text-[13px] text-muted">{timeAgo(patch.created_at)}</Td>
      <Td className="text-right">
        {canWrite && (
          <Menu label="Patch actions" trigger={<MoreHorizontal className="size-4" />}>
            {(close) => (
              <>
                <button className={item} onClick={() => (close(), setDialog('promote'))}>
                  <Rocket className="size-4" /> {patch.channel ? 'Move to channel…' : 'Promote to channel…'}
                </button>
                {patch.channel && (patch.rollout_percentage ?? 100) < 100 && (
                  <button className={item} onClick={() => (close(), setDialog('rollout'))}>
                    <ArrowUpRight className="size-4" /> Increase rollout…
                  </button>
                )}
                <button className={item} onClick={() => (close(), setDialog('notes'))}>
                  <Pencil className="size-4" /> Edit notes
                </button>
                <div className="my-1 border-t border-line" />
                {patch.is_rolled_back ? (
                  <button className={item} onClick={() => (close(), rollback.mutate({ patchId: patch.id, rollback: false }))}>
                    <Undo2 className="size-4" /> Restore patch
                  </button>
                ) : (
                  <button className={clsx(item, 'text-danger')} onClick={() => (close(), setDialog('rollback'))}>
                    <RotateCcw className="size-4" /> Roll back
                  </button>
                )}
              </>
            )}
          </Menu>
        )}
        <PromoteModal open={dialog === 'promote'} onClose={() => setDialog(null)} patch={patch} />
        <RolloutModal open={dialog === 'rollout'} onClose={() => setDialog(null)} patch={patch} releaseId={releaseId} />
        <PatchNotesModal open={dialog === 'notes'} onClose={() => setDialog(null)} patch={patch} releaseId={releaseId} />
        <Confirm
          open={dialog === 'rollback'}
          onClose={() => setDialog(null)}
          title={`Roll back patch #${patch.number}?`}
          description="Devices running it revert to the previous patch (or the release) on their next launch. You can restore it later."
          action="Roll back"
          loading={rollback.isPending}
          onConfirm={() => rollback.mutate({ patchId: patch.id, rollback: true }, { onSuccess: () => setDialog(null) })}
        />
      </Td>
    </tr>
  )
}

const presets = [1, 5, 10, 25, 50, 100]

function PercentPicker({ value, onChange, min = 0.01 }: { value: number; onChange: (v: number) => void; min?: number }) {
  return (
    <div className="space-y-3">
      <div className="flex items-center gap-3">
        <input
          type="range"
          min={0}
          max={100}
          step={1}
          value={value}
          onChange={(e) => onChange(Math.max(min, Number(e.target.value)))}
          className="flex-1 accent-[var(--accent)]"
        />
        <div className="flex items-center rounded-lg border border-line">
          <input
            type="number"
            min={min}
            max={100}
            step={0.01}
            value={value}
            onChange={(e) => onChange(Math.min(100, Math.max(min, Number(e.target.value))))}
            className="h-8 w-20 bg-transparent px-2 text-right text-sm tabular-nums focus:outline-none"
          />
          <span className="pr-2 text-sm text-faint">%</span>
        </div>
      </div>
      <div className="flex flex-wrap gap-1.5">
        {presets
          .filter((p) => p >= min)
          .map((p) => (
            <button
              key={p}
              onClick={() => onChange(p)}
              className={clsx(
                'rounded-md border px-2 py-1 text-[12px]',
                value === p ? 'border-accent bg-accent-soft text-accent' : 'border-line text-muted hover:text-fg',
              )}
            >
              {p}%
            </button>
          ))}
      </div>
    </div>
  )
}

function PromoteModal({ open, onClose, patch }: { open: boolean; onClose: () => void; patch: ReleasePatch }) {
  const { app } = useAppCtx()
  const { data: channels } = useChannels(app.app_id)
  const promote = usePromotePatch(app.app_id)
  const [channelId, setChannelId] = useState<number | null>(null)
  const [pct, setPct] = useState(100)
  useEffect(() => {
    if (!open || !channels) return
    setChannelId(channels.find((c) => c.name === 'stable')?.id ?? channels[0]?.id ?? null)
    setPct(100)
  }, [open, channels])
  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Promote patch #${patch.number}`}
      description="Starts a new rollout on the channel. Devices outside a partial rollout keep the patch they have."
      footer={
        <Button
          variant="primary"
          loading={promote.isPending}
          disabled={!channelId}
          onClick={() =>
            promote.mutate({ patch_id: patch.id, channel_id: channelId!, rollout_percentage: pct }, { onSuccess: onClose })
          }
        >
          Promote
        </Button>
      }
    >
      <div className="space-y-5">
        <Select label="Channel" value={channelId ?? ''} onChange={(e) => setChannelId(Number(e.target.value))}>
          {channels?.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </Select>
        <div>
          <span className="mb-2 block text-[13px] font-medium">Rollout</span>
          <PercentPicker value={pct} onChange={setPct} />
        </div>
      </div>
    </Modal>
  )
}

function RolloutModal({ open, onClose, patch, releaseId }: { open: boolean; onClose: () => void; patch: ReleasePatch; releaseId: number }) {
  const { app } = useAppCtx()
  const set = useSetRollout(app.app_id, releaseId)
  const current = patch.rollout_percentage ?? 100
  const [pct, setPct] = useState(current)
  useEffect(() => setPct(current), [open, current])
  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Increase rollout of patch #${patch.number}`}
      description={`Currently ${current}% of ${patch.channel}. Rollouts only go up: devices already on the patch keep it.`}
      footer={
        <Button variant="primary" loading={set.isPending} disabled={pct <= current} onClick={() => set.mutate({ patchId: patch.id, pct }, { onSuccess: onClose })}>
          Set to {pct}%
        </Button>
      }
    >
      <PercentPicker value={pct} onChange={setPct} min={current} />
    </Modal>
  )
}

function PatchNotesModal({ open, onClose, patch, releaseId }: { open: boolean; onClose: () => void; patch: ReleasePatch; releaseId: number }) {
  const { app } = useAppCtx()
  const update = useUpdatePatchNotes(app.app_id, releaseId)
  const [notes, setNotes] = useState(patch.notes ?? '')
  useEffect(() => setNotes(patch.notes ?? ''), [open, patch.notes])
  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Notes for patch #${patch.number}`}
      footer={
        <Button variant="primary" loading={update.isPending} onClick={() => update.mutate({ patchId: patch.id, notes }, { onSuccess: onClose })}>
          Save
        </Button>
      }
    >
      <textarea
        value={notes}
        onChange={(e) => setNotes(e.target.value)}
        rows={4}
        className="w-full rounded-lg border border-line bg-panel p-3 text-sm focus:border-accent focus:outline-none"
        placeholder="What this patch fixes"
      />
    </Modal>
  )
}

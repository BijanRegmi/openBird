import { ChevronLeft } from 'lucide-react'
import { createContext, useContext, useMemo, useState } from 'react'
import { Link, Outlet, useParams } from 'react-router-dom'
import type { AppMetadata } from '../../api/client'
import type { Range } from '../../api/hooks'
import { useApp, useReleases } from '../../api/hooks'
import { PlatformBadge } from '../../components/platform'
import { CopyButton, ErrorNote, Loading, Segmented, Tabs } from '../../components/ui'

type Period = '24h' | '7d' | '30d' | '90d'

const periods: Record<Period, { ms: number; granularity: Range['granularity'] }> = {
  '24h': { ms: 864e5, granularity: 'hour' },
  '7d': { ms: 7 * 864e5, granularity: 'day' },
  '30d': { ms: 30 * 864e5, granularity: 'day' },
  '90d': { ms: 90 * 864e5, granularity: 'week' },
}

type AppCtx = { app: AppMetadata; range: Range; period: Period; setPeriod: (p: Period) => void }
const Ctx = createContext<AppCtx | null>(null)
export const useAppCtx = () => useContext(Ctx)!

export function PeriodPicker() {
  const { period, setPeriod } = useAppCtx()
  return (
    <Segmented<Period>
      value={period}
      onChange={setPeriod}
      options={(Object.keys(periods) as Period[]).map((p) => ({ value: p, label: p }))}
    />
  )
}

export function AppLayout() {
  const { appId = '' } = useParams()
  const { data: app, isLoading, error } = useApp(appId)
  const { data: releases } = useReleases(appId)
  const [period, setPeriod] = useState<Period>('30d')
  const range = useMemo<Range>(() => {
    // Rounded to the minute so the query keys stay stable between renders.
    const end = new Date(Math.ceil(Date.now() / 60000) * 60000)
    return {
      start: new Date(end.getTime() - periods[period].ms).toISOString(),
      end: end.toISOString(),
      granularity: periods[period].granularity,
    }
  }, [period])
  if (error) return <ErrorNote error={error} />
  if (isLoading || !app) return <Loading />
  const base = `/apps/${appId}`
  return (
    <Ctx.Provider value={{ app, range, period, setPeriod }}>
      <Link to="/apps" className="mb-4 inline-flex items-center gap-1 text-[13px] text-muted hover:text-fg">
        <ChevronLeft className="size-4" /> Apps
      </Link>
      <div className="mb-5 flex flex-wrap items-center gap-4">
        <div className="flex size-12 shrink-0 items-center justify-center rounded-2xl bg-gradient-to-br from-accent to-[var(--chart-2)] text-lg font-semibold text-white">
          {app.display_name.slice(0, 1).toUpperCase()}
        </div>
        <div className="min-w-0 flex-1">
          <h1 className="truncate text-xl font-semibold tracking-tight">{app.display_name}</h1>
          <div className="mt-0.5 flex flex-wrap items-center gap-2">
            <span className="font-mono text-[12px] text-faint">{app.app_id}</span>
            <CopyButton value={app.app_id} />
            {app.platforms?.map((p) => <PlatformBadge key={p} platform={p} />)}
          </div>
        </div>
      </div>
      <div className="mb-6 border-b border-line">
        <Tabs
          items={[
            { to: base, label: 'Overview', end: true },
            { to: `${base}/releases`, label: 'Releases', count: releases?.length },
            { to: `${base}/channels`, label: 'Channels' },
            { to: `${base}/insights`, label: 'Insights' },
            { to: `${base}/events`, label: 'Device events' },
            { to: `${base}/builds`, label: 'Build history' },
            { to: `${base}/settings`, label: 'Settings' },
          ]}
        />
      </div>
      <Outlet />
    </Ctx.Provider>
  )
}

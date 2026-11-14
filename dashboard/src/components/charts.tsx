import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'

import { chartColors } from './share-bars'

export { chartColors }

const axis = { stroke: 'var(--faint)', tick: { fill: 'var(--faint)', fontSize: 11 }, tickLine: false, axisLine: false }

const tooltipStyle = {
  contentStyle: {
    background: 'var(--panel)',
    border: '1px solid var(--line)',
    borderRadius: 8,
    fontSize: 12,
    color: 'var(--fg)',
  },
  labelStyle: { color: 'var(--muted)', marginBottom: 4 },
  cursor: { stroke: 'var(--line)', fill: 'var(--panel-2)' },
}

export const periodLabel = (granularity: string) => (iso: string) => {
  const d = new Date(iso)
  if (granularity === 'hour') return d.toLocaleTimeString(undefined, { hour: 'numeric' })
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

export type Series = { key: string; label: string }

/// Merges per-series time series into recharts rows keyed by period.
export function mergeSeries(series: { key: string; points: { period: string; value: number }[] }[]) {
  const rows = new Map<string, Record<string, number | string>>()
  for (const s of series) {
    for (const p of s.points) {
      const row = rows.get(p.period) ?? { period: p.period }
      row[s.key] = p.value
      rows.set(p.period, row)
    }
  }
  return [...rows.values()]
    .sort((a, b) => String(a.period).localeCompare(String(b.period)))
    .map((row) => {
      for (const s of series) row[s.key] ??= 0
      return row
    })
}

export function TimeChart({
  data,
  series,
  granularity,
  kind = 'area',
  height = 240,
  stacked,
  percent,
  xFormat,
}: {
  data: Record<string, number | string>[]
  series: Series[]
  granularity: string
  kind?: 'area' | 'bar' | 'line'
  height?: number
  stacked?: boolean
  percent?: boolean
  xFormat?: (iso: string) => string
}) {
  const fmt = xFormat ?? periodLabel(granularity)
  // Recharts finds axes, tooltip and legend among its direct children only,
  // so these go in as a keyed array rather than a fragment.
  const common = [
    <CartesianGrid key="grid" stroke="var(--line)" strokeDasharray="3 3" vertical={false} />,
    <XAxis key="x" dataKey="period" tickFormatter={fmt} {...axis} minTickGap={24} />,
    <YAxis key="y" {...axis} width={40} allowDecimals={false} tickFormatter={percent ? (v) => `${v}%` : undefined} />,
    <Tooltip
      key="tooltip"
      {...tooltipStyle}
      labelFormatter={(v) => new Date(String(v)).toLocaleString()}
      formatter={(v: number, name) => [percent ? `${v.toFixed(1)}%` : v.toLocaleString(), name]}
    />,
    series.length > 1 ? <Legend key="legend" iconType="circle" iconSize={8} wrapperStyle={{ fontSize: 12 }} /> : null,
  ]
  return (
    <ResponsiveContainer width="100%" height={height}>
      {kind === 'bar' ? (
        <BarChart data={data}>
          {common}
          {series.map((s, i) => (
            <Bar key={s.key} dataKey={s.key} name={s.label} stackId={stacked ? 'a' : undefined} fill={chartColors[i % 5]} radius={stacked ? 0 : [3, 3, 0, 0]} />
          ))}
        </BarChart>
      ) : kind === 'line' ? (
        <LineChart data={data}>
          {common}
          {series.map((s, i) => (
            <Line key={s.key} dataKey={s.key} name={s.label} stroke={chartColors[i % 5]} strokeWidth={2} dot={false} type="monotone" />
          ))}
        </LineChart>
      ) : (
        <AreaChart data={data}>
          <defs>
            {series.map((s, i) => (
              <linearGradient key={s.key} id={`g-${s.key}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={chartColors[i % 5]} stopOpacity={0.3} />
                <stop offset="100%" stopColor={chartColors[i % 5]} stopOpacity={0} />
              </linearGradient>
            ))}
          </defs>
          {common}
          {series.map((s, i) => (
            <Area
              key={s.key}
              dataKey={s.key}
              name={s.label}
              type="monotone"
              stroke={chartColors[i % 5]}
              strokeWidth={2}
              fill={`url(#g-${s.key})`}
              stackId={stacked ? 'a' : undefined}
            />
          ))}
        </AreaChart>
      )}
    </ResponsiveContainer>
  )
}

export { ShareBars } from './share-bars'

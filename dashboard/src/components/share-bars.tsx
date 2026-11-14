// Kept apart from charts.tsx so pages that only need these bars don't load
// recharts.

export const chartColors = ['var(--chart-1)', 'var(--chart-2)', 'var(--chart-3)', 'var(--chart-4)', 'var(--chart-5)']

/// Horizontal share bars, e.g. version distribution.
export function ShareBars({ rows }: { rows: { label: string; value: number; pct: number }[] }) {
  return (
    <div className="space-y-3">
      {rows.map((r, i) => (
        <div key={r.label}>
          <div className="mb-1 flex justify-between text-[13px]">
            <span className="font-mono">{r.label}</span>
            <span className="text-muted tabular-nums">
              {r.value.toLocaleString()} · {r.pct.toFixed(1)}%
            </span>
          </div>
          <div className="h-2 overflow-hidden rounded-full bg-panel-2">
            <div className="h-full rounded-full" style={{ width: `${Math.max(r.pct, 1)}%`, background: chartColors[i % 5] }} />
          </div>
        </div>
      ))}
    </div>
  )
}

const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' })

export function timeAgo(iso?: string | null): string {
  if (!iso) return 'never'
  const diff = (new Date(iso).getTime() - Date.now()) / 1000
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ['year', 31536000],
    ['month', 2592000],
    ['week', 604800],
    ['day', 86400],
    ['hour', 3600],
    ['minute', 60],
  ]
  for (const [unit, secs] of units) {
    if (Math.abs(diff) >= secs) return rtf.format(Math.round(diff / secs), unit)
  }
  return 'just now'
}

export const dateTime = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '—'

export const date = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleDateString(undefined, { dateStyle: 'medium' }) : '—'

export const num = (n?: number | null) => (n ?? 0).toLocaleString()

export const compact = (n?: number | null) =>
  Intl.NumberFormat(undefined, { notation: 'compact', maximumFractionDigits: 1 }).format(n ?? 0)

export function bytes(n?: number | null): string {
  let v = n ?? 0
  const units = ['B', 'KB', 'MB', 'GB']
  let i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return `${v.toFixed(v >= 10 || i === 0 ? 0 : 1)} ${units[i]}`
}

export const duration = (ms?: number | null) => {
  if (!ms) return '—'
  const s = Math.round(ms / 1000)
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

/// Percentage change between windows, or null when there's no baseline.
export const delta = (current: number, previous?: number | null) =>
  previous ? ((current - previous) / previous) * 100 : null

export const platformLabel: Record<string, string> = {
  android: 'Android',
  ios: 'iOS',
  macos: 'macOS',
  windows: 'Windows',
  linux: 'Linux',
}

export const roleLabel: Record<string, string> = {
  owner: 'Owner',
  admin: 'Admin',
  appManager: 'App manager',
  developer: 'Developer',
  viewer: 'Viewer',
  auditor: 'Auditor',
}

export const eventLabel: Record<string, string> = {
  __patch_install__: 'Installed',
  __patch_install_failure__: 'Install failed',
  __patch_download__: 'Downloaded',
  __patch_update_failure__: 'Update failed',
}

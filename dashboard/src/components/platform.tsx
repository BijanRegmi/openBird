import clsx from 'clsx'
import { AppWindow, Monitor, Smartphone, Terminal } from 'lucide-react'
import { platformLabel } from '../lib/format'

export function PlatformIcon({ platform, className }: { platform: string; className?: string }) {
  const cls = clsx('size-3.5', className)
  switch (platform) {
    case 'android':
      return (
        <svg viewBox="0 0 24 24" className={cls} fill="currentColor" aria-hidden>
          <path d="M17.6 9.48 19.44 6.3a.37.37 0 0 0-.64-.37l-1.86 3.22a11.4 11.4 0 0 0-9.88 0L5.2 5.93a.37.37 0 0 0-.64.37L6.4 9.48A10.8 10.8 0 0 0 1 18h22a10.8 10.8 0 0 0-5.4-8.52ZM7 15.25a1.25 1.25 0 1 1 1.25-1.25A1.25 1.25 0 0 1 7 15.25Zm10 0A1.25 1.25 0 1 1 18.25 14 1.25 1.25 0 0 1 17 15.25Z" />
        </svg>
      )
    case 'ios':
      return <Smartphone className={cls} />
    case 'macos':
      return <Monitor className={cls} />
    case 'windows':
      return <AppWindow className={cls} />
    default:
      return <Terminal className={cls} />
  }
}

export function PlatformBadge({ platform }: { platform: string }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-md border border-line px-1.5 py-0.5 text-[12px] text-muted">
      <PlatformIcon platform={platform} />
      {platformLabel[platform] ?? platform}
    </span>
  )
}

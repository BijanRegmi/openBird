import clsx from 'clsx'
import { Check, Copy, Loader2, X } from 'lucide-react'
import {
  useEffect,
  useState,
  type ButtonHTMLAttributes,
  type InputHTMLAttributes,
  type ReactNode,
  type SelectHTMLAttributes,
} from 'react'
import { createPortal } from 'react-dom'
import { NavLink } from 'react-router-dom'
import { delta } from '../lib/format'

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger'

export function Button({
  variant = 'secondary',
  size = 'md',
  loading,
  icon,
  className,
  children,
  disabled,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant
  size?: 'sm' | 'md'
  loading?: boolean
  icon?: ReactNode
}) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={clsx(
        'inline-flex items-center justify-center gap-1.5 rounded-lg font-medium whitespace-nowrap transition-colors',
        'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-50',
        size === 'sm' ? 'h-8 px-2.5 text-[13px]' : 'h-9 px-3.5 text-sm',
        variant === 'primary' && 'bg-accent text-accent-fg hover:brightness-110',
        variant === 'secondary' && 'border border-line bg-panel text-fg hover:bg-panel-2',
        variant === 'ghost' && 'text-muted hover:bg-panel-2 hover:text-fg',
        variant === 'danger' && 'bg-danger text-white hover:brightness-110',
        className,
      )}
    >
      {loading ? <Loader2 className="size-4 animate-spin" /> : icon}
      {children}
    </button>
  )
}

export function Card({ className, children }: { className?: string; children: ReactNode }) {
  return <div className={clsx('rounded-xl border border-line bg-panel', className)}>{children}</div>
}

export function CardHeader({
  title,
  description,
  actions,
}: {
  title: ReactNode
  description?: ReactNode
  actions?: ReactNode
}) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-3 border-b border-line px-5 py-4">
      <div className="min-w-0">
        <h3 className="text-[15px] font-semibold">{title}</h3>
        {description && <p className="mt-0.5 text-[13px] text-muted">{description}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  )
}

type Tone = 'neutral' | 'accent' | 'ok' | 'warn' | 'danger'

export function Badge({ tone = 'neutral', children, className }: { tone?: Tone; children: ReactNode; className?: string }) {
  return (
    <span
      className={clsx(
        'inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[12px] font-medium whitespace-nowrap',
        tone === 'neutral' && 'bg-panel-2 text-muted',
        tone === 'accent' && 'bg-accent-soft text-accent',
        tone === 'ok' && 'bg-ok-soft text-ok',
        tone === 'warn' && 'bg-warn-soft text-warn',
        tone === 'danger' && 'bg-danger-soft text-danger',
        className,
      )}
    >
      {children}
    </span>
  )
}

export function Input({ label, hint, className, ...rest }: InputHTMLAttributes<HTMLInputElement> & { label?: string; hint?: ReactNode }) {
  return (
    <label className="block">
      {label && <span className="mb-1.5 block text-[13px] font-medium">{label}</span>}
      <input
        {...rest}
        className={clsx(
          'h-9 w-full rounded-lg border border-line bg-panel px-3 text-sm text-fg placeholder:text-faint',
          'focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/20',
          className,
        )}
      />
      {hint && <span className="mt-1 block text-[12px] text-faint">{hint}</span>}
    </label>
  )
}

export function Select({ label, className, children, ...rest }: SelectHTMLAttributes<HTMLSelectElement> & { label?: string }) {
  return (
    <label className="block">
      {label && <span className="mb-1.5 block text-[13px] font-medium">{label}</span>}
      <select
        {...rest}
        className={clsx(
          'h-9 w-full rounded-lg border border-line bg-panel px-2.5 text-sm text-fg focus:border-accent focus:outline-none',
          className,
        )}
      >
        {children}
      </select>
    </label>
  )
}

export function Modal({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  wide,
}: {
  open: boolean
  onClose: () => void
  title: ReactNode
  description?: ReactNode
  children?: ReactNode
  footer?: ReactNode
  wide?: boolean
}) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])
  if (!open) return null
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 pt-[12vh] backdrop-blur-[2px]" onMouseDown={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        className={clsx('w-full rounded-xl border border-line bg-panel shadow-2xl', wide ? 'max-w-2xl' : 'max-w-md')}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-4 px-5 pt-5">
          <div>
            <h2 className="text-base font-semibold">{title}</h2>
            {description && <p className="mt-1 text-[13px] text-muted">{description}</p>}
          </div>
          <button onClick={onClose} className="rounded-md p-1 text-faint hover:bg-panel-2 hover:text-fg" aria-label="Close">
            <X className="size-4" />
          </button>
        </div>
        {children && <div className="px-5 py-4">{children}</div>}
        {footer && <div className="flex justify-end gap-2 border-t border-line px-5 py-3">{footer}</div>}
      </div>
    </div>,
    document.body,
  )
}

/// A confirmation step for destructive or hard-to-undo actions. With
/// [confirmText], the user types it to enable the button.
export function Confirm({
  open,
  onClose,
  onConfirm,
  title,
  description,
  action,
  confirmText,
  loading,
  danger = true,
}: {
  open: boolean
  onClose: () => void
  onConfirm: () => void
  title: string
  description: ReactNode
  action: string
  confirmText?: string
  loading?: boolean
  danger?: boolean
}) {
  const [typed, setTyped] = useState('')
  useEffect(() => setTyped(''), [open])
  return (
    <Modal
      open={open}
      onClose={onClose}
      title={title}
      description={description}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant={danger ? 'danger' : 'primary'}
            loading={loading}
            disabled={confirmText !== undefined && typed !== confirmText}
            onClick={onConfirm}
          >
            {action}
          </Button>
        </>
      }
    >
      {confirmText !== undefined && (
        <Input
          autoFocus
          label={`Type ${confirmText} to confirm`}
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
          className="font-mono"
        />
      )}
    </Modal>
  )
}

export function CopyButton({ value, label, className }: { value: string; label?: string; className?: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type="button"
      onClick={async () => {
        await navigator.clipboard.writeText(value)
        setCopied(true)
        setTimeout(() => setCopied(false), 1500)
      }}
      className={clsx(
        'inline-flex items-center gap-1.5 rounded-md px-1.5 py-1 text-[12px] text-muted hover:bg-panel-2 hover:text-fg',
        className,
      )}
      title="Copy"
    >
      {copied ? <Check className="size-3.5 text-ok" /> : <Copy className="size-3.5" />}
      {label}
    </button>
  )
}

export function Code({ children, copy }: { children: string; copy?: boolean }) {
  return (
    <div className="group relative">
      <pre className="overflow-x-auto rounded-lg border border-line bg-panel-2 px-3.5 py-3 font-mono text-[12.5px] leading-relaxed">
        {children}
      </pre>
      {copy && <CopyButton value={children} className="absolute top-1.5 right-1.5 bg-panel opacity-0 group-hover:opacity-100" />}
    </div>
  )
}

export function Spinner({ className }: { className?: string }) {
  return <Loader2 className={clsx('size-5 animate-spin text-faint', className)} />
}

export function Loading() {
  return (
    <div className="flex h-40 items-center justify-center">
      <Spinner />
    </div>
  )
}

export function Empty({ icon, title, children, action }: { icon?: ReactNode; title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center px-6 py-12 text-center">
      {icon && <div className="mb-3 rounded-xl bg-panel-2 p-3 text-faint">{icon}</div>}
      <p className="font-medium">{title}</p>
      {children && <div className="mt-1 max-w-md text-[13px] text-muted">{children}</div>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  )
}

export function ErrorNote({ error }: { error: unknown }) {
  return (
    <div className="rounded-lg border border-danger/30 bg-danger-soft px-4 py-3 text-sm text-danger">
      {error instanceof Error ? error.message : 'Something went wrong.'}
    </div>
  )
}

export function Stat({
  label,
  value,
  current,
  previous,
  hint,
  icon,
}: {
  label: string
  value: ReactNode
  current?: number
  previous?: number | null
  hint?: ReactNode
  icon?: ReactNode
}) {
  const change = current !== undefined ? delta(current, previous) : null
  return (
    <Card className="p-4">
      <div className="flex items-center justify-between text-[13px] text-muted">
        <span>{label}</span>
        {icon && <span className="text-faint">{icon}</span>}
      </div>
      <div className="mt-2 flex items-baseline gap-2">
        <span className="text-2xl font-semibold tracking-tight tabular-nums">{value}</span>
        {change !== null && (
          <span className={clsx('text-[12px] font-medium', change >= 0 ? 'text-ok' : 'text-danger')}>
            {change >= 0 ? '+' : ''}
            {change.toFixed(0)}%
          </span>
        )}
      </div>
      {hint && <div className="mt-1 text-[12px] text-faint">{hint}</div>}
    </Card>
  )
}

export function Tabs({ items }: { items: { to: string; label: string; end?: boolean; count?: number }[] }) {
  return (
    <nav className="-mb-px flex gap-1 overflow-x-auto">
      {items.map((item) => (
        <NavLink
          key={item.to}
          to={item.to}
          end={item.end}
          className={({ isActive }) =>
            clsx(
              'flex items-center gap-1.5 border-b-2 px-3 py-2.5 text-sm font-medium whitespace-nowrap transition-colors',
              isActive ? 'border-accent text-fg' : 'border-transparent text-muted hover:text-fg',
            )
          }
        >
          {item.label}
          {item.count !== undefined && <span className="rounded-full bg-panel-2 px-1.5 text-[11px] text-faint">{item.count}</span>}
        </NavLink>
      ))}
    </nav>
  )
}

export function Segmented<T extends string>({
  value,
  onChange,
  options,
}: {
  value: T
  onChange: (v: T) => void
  options: { value: T; label: string }[]
}) {
  return (
    <div className="inline-flex rounded-lg border border-line bg-panel-2 p-0.5">
      {options.map((o) => (
        <button
          key={o.value}
          onClick={() => onChange(o.value)}
          className={clsx(
            'rounded-md px-2.5 py-1 text-[13px] font-medium transition-colors',
            value === o.value ? 'bg-panel text-fg shadow-sm' : 'text-muted hover:text-fg',
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

export function Table({ head, children }: { head: ReactNode[]; children: ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-line text-left text-[12px] font-medium tracking-wide text-faint uppercase">
            {head.map((h, i) => (
              <th key={i} className="px-5 py-2.5 font-medium">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-line">{children}</tbody>
      </table>
    </div>
  )
}

export function Td({ children, className }: { children?: ReactNode; className?: string }) {
  return <td className={clsx('px-5 py-3 align-middle', className)}>{children}</td>
}

export function PageHeader({ title, description, actions }: { title: ReactNode; description?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        <h1 className="text-xl font-semibold tracking-tight">{title}</h1>
        {description && <p className="mt-1 text-sm text-muted">{description}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  )
}

/// A dropdown rendered in a portal and positioned against its trigger, so
/// scrolling containers (tables) don't clip it.
export function Menu({ trigger, children, label }: { trigger: ReactNode; children: (close: () => void) => ReactNode; label: string }) {
  const [rect, setRect] = useState<DOMRect | null>(null)
  const close = () => setRect(null)
  useEffect(() => {
    if (!rect) return
    const onDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest('[data-menu]')) close()
    }
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close()
    document.addEventListener('mousedown', onDown)
    window.addEventListener('scroll', close, true)
    window.addEventListener('resize', close)
    window.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      window.removeEventListener('scroll', close, true)
      window.removeEventListener('resize', close)
      window.removeEventListener('keydown', onKey)
    }
  }, [rect])
  const width = 208
  return (
    <>
      <button
        data-menu
        aria-label={label}
        aria-expanded={!!rect}
        onClick={(e) => setRect(rect ? null : e.currentTarget.getBoundingClientRect())}
        className="rounded-md p-1.5 text-muted hover:bg-panel-2 hover:text-fg"
      >
        {trigger}
      </button>
      {rect &&
        createPortal(
          <div
            data-menu
            role="menu"
            className="fixed z-40 rounded-lg border border-line bg-panel p-1 text-left shadow-xl"
            style={{
              width,
              left: Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8)),
              ...(rect.bottom + 220 > window.innerHeight ? { bottom: window.innerHeight - rect.top + 4 } : { top: rect.bottom + 4 }),
            }}
          >
            {children(close)}
          </div>,
          document.body,
        )}
    </>
  )
}

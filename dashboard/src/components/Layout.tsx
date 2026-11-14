import clsx from 'clsx'
import {
  BarChart3,
  Boxes,
  Building2,
  ChevronsUpDown,
  KeyRound,
  LogOut,
  Mail,
  Menu,
  Moon,
  Plus,
  Sun,
  User,
  Users,
  X,
} from 'lucide-react'
import { Suspense, useEffect, useRef, useState } from 'react'
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useCreateOrganization, useLogout, useMe } from '../api/hooks'
import { roleLabel } from '../lib/format'
import { useOrg } from '../lib/org'
import { Button, Input, Loading, Modal } from './ui'

export function Logo({ className }: { className?: string }) {
  return (
    <div className={clsx('flex items-center gap-2', className)}>
      <svg viewBox="0 0 32 32" className="size-7" aria-hidden>
        <rect width="32" height="32" rx="8" className="fill-accent" />
        <path d="M9 17.5 14.5 12l3 3L23 9.5M23 9.5h-4.5M23 9.5V14" className="stroke-accent-fg" strokeWidth="2.4" fill="none" strokeLinecap="round" strokeLinejoin="round" />
        <path d="M9 23h14" className="stroke-accent-fg/60" strokeWidth="2.4" strokeLinecap="round" />
      </svg>
      <span className="text-[15px] font-semibold tracking-tight">openBird</span>
    </div>
  )
}

function useTheme() {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains('dark'))
  const toggle = () => {
    const next = !dark
    setDark(next)
    document.documentElement.classList.toggle('dark', next)
    try {
      localStorage.setItem('theme', next ? 'dark' : 'light')
    } catch {
      /* per-viewer convenience only */
    }
  }
  return { dark, toggle }
}

function OrgSwitcher() {
  const { orgs, current, setCurrent } = useOrg()
  const [open, setOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const create = useCreateOrganization()
  const ref = useRef<HTMLDivElement>(null)
  const navigate = useNavigate()
  useEffect(() => {
    const close = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false)
    document.addEventListener('mousedown', close)
    return () => document.removeEventListener('mousedown', close)
  }, [])
  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-2.5 rounded-lg border border-line bg-panel px-2.5 py-2 text-left hover:bg-panel-2"
      >
        <div className="flex size-7 shrink-0 items-center justify-center rounded-md bg-accent-soft text-[13px] font-semibold text-accent">
          {current?.organization.name.slice(0, 1).toUpperCase() ?? '·'}
        </div>
        <div className="min-w-0 flex-1">
          <div className="truncate text-[13px] font-medium">{current?.organization.name ?? 'No organization'}</div>
          <div className="text-[11px] text-faint">
            {current ? `${current.organization.organization_type === 'personal' ? 'Personal' : 'Team'} · ${roleLabel[current.role] ?? current.role}` : ''}
          </div>
        </div>
        <ChevronsUpDown className="size-4 text-faint" />
      </button>
      {open && (
        <div className="absolute inset-x-0 top-full z-30 mt-1 rounded-lg border border-line bg-panel p-1 shadow-xl">
          {orgs.map((o) => (
            <button
              key={o.organization.id}
              onClick={() => {
                setCurrent(o.organization.id)
                setOpen(false)
                navigate('/apps')
              }}
              className={clsx(
                'flex w-full items-center justify-between rounded-md px-2.5 py-2 text-left text-[13px] hover:bg-panel-2',
                o.organization.id === current?.organization.id && 'text-accent',
              )}
            >
              <span className="truncate">{o.organization.name}</span>
              <span className="text-[11px] text-faint">{roleLabel[o.role]}</span>
            </button>
          ))}
          <div className="my-1 border-t border-line" />
          <button
            onClick={() => {
              setOpen(false)
              setCreating(true)
            }}
            className="flex w-full items-center gap-2 rounded-md px-2.5 py-2 text-[13px] text-muted hover:bg-panel-2 hover:text-fg"
          >
            <Plus className="size-4" /> New team organization
          </button>
        </div>
      )}
      <Modal
        open={creating}
        onClose={() => setCreating(false)}
        title="New organization"
        description="Teams share apps. Invite members once it exists."
        footer={
          <Button
            variant="primary"
            loading={create.isPending}
            disabled={!name.trim()}
            onClick={() =>
              create.mutate(
                { name: name.trim() },
                {
                  onSuccess: (org) => {
                    setCurrent(org.id)
                    setCreating(false)
                    setName('')
                    navigate('/apps')
                  },
                },
              )
            }
          >
            Create
          </Button>
        }
      >
        <Input autoFocus label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Acme Mobile" />
      </Modal>
    </div>
  )
}

const nav = [
  { to: '/apps', label: 'Apps', icon: Boxes },
  { to: '/members', label: 'Members', icon: Users },
  { to: '/usage', label: 'Usage', icon: BarChart3 },
  { to: '/api-keys', label: 'API keys', icon: KeyRound },
  { to: '/organization', label: 'Organization', icon: Building2 },
]

function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  const { data: me } = useMe()
  const logout = useLogout()
  const navigate = useNavigate()
  const { dark, toggle } = useTheme()
  return (
    <div className="flex h-full flex-col gap-4 p-3">
      <div className="px-1.5 pt-1">
        <Logo />
      </div>
      <OrgSwitcher />
      <nav className="flex flex-col gap-0.5">
        {nav.map(({ to, label, icon: Icon }) => (
          <NavLink
            key={to}
            to={to}
            onClick={onNavigate}
            className={({ isActive }) =>
              clsx(
                'flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium transition-colors',
                isActive ? 'bg-accent-soft text-accent' : 'text-muted hover:bg-panel-2 hover:text-fg',
              )
            }
          >
            <Icon className="size-4" />
            {label}
          </NavLink>
        ))}
        <NavLink
          to="/invitations"
          onClick={onNavigate}
          className={({ isActive }) =>
            clsx(
              'flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm font-medium transition-colors',
              isActive ? 'bg-accent-soft text-accent' : 'text-muted hover:bg-panel-2 hover:text-fg',
            )
          }
        >
          <Mail className="size-4" />
          Invitations
          {!!me?.pending_invitations && (
            <span className="ml-auto rounded-full bg-accent px-1.5 text-[11px] font-semibold text-accent-fg">{me.pending_invitations}</span>
          )}
        </NavLink>
      </nav>
      <div className="mt-auto flex flex-col gap-0.5 border-t border-line pt-3">
        <button onClick={toggle} className="flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm text-muted hover:bg-panel-2 hover:text-fg">
          {dark ? <Sun className="size-4" /> : <Moon className="size-4" />}
          {dark ? 'Light theme' : 'Dark theme'}
        </button>
        <NavLink
          to="/account"
          onClick={onNavigate}
          className={({ isActive }) =>
            clsx('flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm hover:bg-panel-2', isActive ? 'text-accent' : 'text-muted hover:text-fg')
          }
        >
          <User className="size-4" />
          <span className="truncate">{me?.display_name || me?.email}</span>
        </NavLink>
        <button
          onClick={() => logout.mutate(undefined, { onSuccess: () => navigate('/login') })}
          className="flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm text-muted hover:bg-panel-2 hover:text-fg"
        >
          <LogOut className="size-4" />
          Sign out
        </button>
      </div>
    </div>
  )
}

export function Layout() {
  const [open, setOpen] = useState(false)
  const location = useLocation()
  useEffect(() => setOpen(false), [location.pathname])
  return (
    <div className="flex min-h-full">
      <aside className="sticky top-0 hidden h-screen w-64 shrink-0 border-r border-line bg-panel/60 lg:block">
        <Sidebar />
      </aside>
      {open && (
        <div className="fixed inset-0 z-40 lg:hidden" onClick={() => setOpen(false)}>
          <div className="absolute inset-0 bg-black/40" />
          <aside className="absolute inset-y-0 left-0 w-72 border-r border-line bg-panel" onClick={(e) => e.stopPropagation()}>
            <Sidebar onNavigate={() => setOpen(false)} />
          </aside>
        </div>
      )}
      <div className="min-w-0 flex-1">
        <header className="sticky top-0 z-20 flex items-center justify-between border-b border-line bg-panel/80 px-4 py-2.5 backdrop-blur lg:hidden">
          <Logo />
          <button onClick={() => setOpen(true)} className="rounded-md p-1.5 text-muted hover:bg-panel-2" aria-label="Menu">
            {open ? <X className="size-5" /> : <Menu className="size-5" />}
          </button>
        </header>
        <main className="mx-auto max-w-6xl px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
          <Suspense fallback={<Loading />}>
            <Outlet />
          </Suspense>
        </main>
      </div>
    </div>
  )
}

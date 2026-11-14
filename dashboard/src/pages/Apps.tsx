import { Boxes, Plus, Search } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useConfig, useCreateApp, useOrgApps } from '../api/hooks'
import { PlatformBadge } from '../components/platform'
import { Badge, Button, Card, Code, Empty, ErrorNote, Input, Loading, Modal, PageHeader } from '../components/ui'
import { timeAgo } from '../lib/format'
import { useOrg } from '../lib/org'

export function AppsPage() {
  const { current, canWrite } = useOrg()
  const { data: apps, isLoading, error } = useOrgApps(current?.organization.id)
  const [query, setQuery] = useState('')
  const [creating, setCreating] = useState(false)
  const filtered = useMemo(
    () => (apps ?? []).filter((a) => a.display_name.toLowerCase().includes(query.toLowerCase()) || a.app_id.includes(query)),
    [apps, query],
  )
  return (
    <>
      <PageHeader
        title="Apps"
        description={current ? `Apps in ${current.organization.name}` : undefined}
        actions={
          canWrite && (
            <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setCreating(true)}>
              New app
            </Button>
          )
        }
      />
      {error ? (
        <ErrorNote error={error} />
      ) : isLoading ? (
        <Loading />
      ) : !apps?.length ? (
        <Card>
          <Empty
            icon={<Boxes className="size-6" />}
            title="No apps yet"
            action={
              canWrite && (
                <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setCreating(true)}>
                  Create your first app
                </Button>
              )
            }
          >
            Create one here, or run <code className="font-mono">shorebird init</code> in your Flutter project.
          </Empty>
        </Card>
      ) : (
        <>
          <div className="relative mb-4 max-w-sm">
            <Search className="pointer-events-none absolute top-2.5 left-3 size-4 text-faint" />
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search apps"
              className="h-9 w-full rounded-lg border border-line bg-panel pr-3 pl-9 text-sm placeholder:text-faint focus:border-accent focus:outline-none"
            />
          </div>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {filtered.map((app) => (
              <Link key={app.app_id} to={`/apps/${app.app_id}`} className="group">
                <Card className="h-full p-5 transition-all group-hover:border-accent/50 group-hover:shadow-lg group-hover:shadow-accent/5">
                  <div className="flex items-start gap-3">
                    <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-accent to-[var(--chart-2)] text-base font-semibold text-white">
                      {app.display_name.slice(0, 1).toUpperCase()}
                    </div>
                    <div className="min-w-0">
                      <p className="truncate font-semibold">{app.display_name}</p>
                      <p className="truncate font-mono text-[11px] text-faint">{app.app_id}</p>
                    </div>
                  </div>
                  <div className="mt-4 flex flex-wrap gap-1.5">
                    {app.platforms?.length ? app.platforms.map((p) => <PlatformBadge key={p} platform={p} />) : <Badge>No releases</Badge>}
                  </div>
                  <div className="mt-4 grid grid-cols-2 gap-3 border-t border-line pt-3 text-[12px]">
                    <div>
                      <div className="text-faint">Latest release</div>
                      <div className="mt-0.5 truncate font-mono font-medium">{app.latest_release_version ?? '—'}</div>
                    </div>
                    <div>
                      <div className="text-faint">Latest patch</div>
                      <div className="mt-0.5 font-medium">{app.latest_patch_number ? `#${app.latest_patch_number}` : '—'}</div>
                    </div>
                  </div>
                  <div className="mt-3 text-[11px] text-faint">Updated {timeAgo(app.updated_at)}</div>
                </Card>
              </Link>
            ))}
          </div>
        </>
      )}
      <CreateAppModal open={creating} onClose={() => setCreating(false)} />
    </>
  )
}

function CreateAppModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { current } = useOrg()
  const { data: config } = useConfig()
  const create = useCreateApp()
  const [name, setName] = useState('')
  const [created, setCreated] = useState<string | null>(null)
  const navigate = useNavigate()
  const close = () => {
    setName('')
    setCreated(null)
    onClose()
  }
  const base = config?.api_base_url ?? window.location.origin
  return (
    <Modal
      open={open}
      onClose={close}
      wide={!!created}
      title={created ? 'App created' : 'New app'}
      description={created ? 'Add this to shorebird.yaml in your Flutter project, then release.' : 'One app per Flutter project (or flavor).'}
      footer={
        created ? (
          <Button variant="primary" onClick={() => navigate(`/apps/${created}`)}>
            Open app
          </Button>
        ) : (
          <Button
            variant="primary"
            loading={create.isPending}
            disabled={!name.trim() || !current}
            onClick={() =>
              create.mutate(
                { display_name: name.trim(), organization_id: current!.organization.id },
                { onSuccess: (app) => setCreated(app.id) },
              )
            }
          >
            Create app
          </Button>
        )
      }
    >
      {created ? (
        <div className="space-y-4">
          <Code copy>{`# shorebird.yaml\napp_id: ${created}\nbase_url: ${base}\nauto_update: true`}</Code>
          <Code copy>{`export SHOREBIRD_TOKEN=<an API key from API keys>\nshorebird release android\nshorebird patch android`}</Code>
        </div>
      ) : (
        <Input autoFocus label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="My App" />
      )}
    </Modal>
  )
}

import { KeyRound, Mail, Plus, Trash2, UserPlus, Users } from 'lucide-react'
import { useEffect, useState } from 'react'
import type { Role } from '../api/client'
import {
  useApiKeys,
  useChangePassword,
  useConfig,
  useCreateApiKey,
  useInvite,
  useMe,
  useOrgInvitations,
  useOrgUsers,
  useReceivedInvitations,
  useRemoveMember,
  useRenameOrganization,
  useRespondInvitation,
  useRevokeApiKey,
  useRevokeInvitation,
  useSetMemberRole,
  useUpdateProfile,
  useUsage,
} from '../api/hooks'
import { ShareBars } from '../components/share-bars'
import {
  Badge,
  Button,
  Card,
  CardHeader,
  Code,
  Confirm,
  CopyButton,
  Empty,
  Input,
  Loading,
  Modal,
  PageHeader,
  Select,
  Stat,
  Table,
  Td,
} from '../components/ui'
import { date, num, roleLabel, timeAgo } from '../lib/format'
import { useOrg } from '../lib/org'

const roles: Role[] = ['owner', 'admin', 'appManager', 'developer', 'viewer']

const roleHelp: Record<string, string> = {
  owner: 'Everything, including deleting the organization',
  admin: 'Manage members, apps and settings',
  appManager: 'Manage apps, releases and patches',
  developer: 'Release and patch apps',
  viewer: 'Read-only',
}

export function MembersPage() {
  const { current, isAdmin } = useOrg()
  const orgId = current?.organization.id
  const { data: me } = useMe()
  const { data: users, isLoading } = useOrgUsers(orgId)
  const { data: invitations } = useOrgInvitations(orgId)
  const setRole = useSetMemberRole(orgId ?? 0)
  const remove = useRemoveMember(orgId ?? 0)
  const revoke = useRevokeInvitation(orgId ?? 0)
  const [inviting, setInviting] = useState(false)
  const [removing, setRemoving] = useState<{ id: number; email: string } | null>(null)
  return (
    <>
      <PageHeader
        title="Members"
        description={`People in ${current?.organization.name ?? 'this organization'}`}
        actions={
          isAdmin && (
            <Button variant="primary" icon={<UserPlus className="size-4" />} onClick={() => setInviting(true)}>
              Invite
            </Button>
          )
        }
      />
      <Card>
        {isLoading ? (
          <Loading />
        ) : (
          <Table head={['Member', 'Role', '']}>
            {users?.map((u) => (
              <tr key={u.user.id}>
                <Td>
                  <div className="flex items-center gap-3">
                    <div className="flex size-8 items-center justify-center rounded-full bg-panel-2 text-[13px] font-semibold text-muted">
                      {(u.user.display_name || u.user.email).slice(0, 1).toUpperCase()}
                    </div>
                    <div>
                      <div className="font-medium">
                        {u.user.display_name || u.user.email}
                        {u.user.id === me?.id && <span className="ml-2 text-[12px] text-faint">(you)</span>}
                      </div>
                      <div className="text-[12px] text-faint">{u.user.email}</div>
                    </div>
                  </div>
                </Td>
                <Td>
                  {isAdmin ? (
                    <select
                      value={u.role}
                      onChange={(e) => setRole.mutate({ userId: u.user.id, role: e.target.value as Role })}
                      className="h-8 rounded-lg border border-line bg-panel px-2 text-[13px]"
                    >
                      {roles.map((r) => (
                        <option key={r} value={r}>
                          {roleLabel[r]}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <Badge>{roleLabel[u.role] ?? u.role}</Badge>
                  )}
                </Td>
                <Td className="text-right">
                  {(isAdmin || u.user.id === me?.id) && (
                    <Button variant="ghost" size="sm" icon={<Trash2 className="size-4" />} onClick={() => setRemoving({ id: u.user.id, email: u.user.email })}>
                      {u.user.id === me?.id ? 'Leave' : 'Remove'}
                    </Button>
                  )}
                </Td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
      {!!invitations?.length && (
        <Card className="mt-6">
          <CardHeader title="Pending invitations" description="Invitees see these after signing in, and can sign up with the invited email." />
          <Table head={['Email', 'Role', 'Expires', '']}>
            {invitations.map((i) => (
              <tr key={i.id}>
                <Td className="font-medium">{i.email}</Td>
                <Td>
                  <Badge>{roleLabel[i.role]}</Badge>
                </Td>
                <Td className="text-[13px] text-muted">{date(i.expires_at)}</Td>
                <Td className="text-right">
                  {isAdmin && (
                    <Button variant="ghost" size="sm" onClick={() => revoke.mutate(i.id)}>
                      Revoke
                    </Button>
                  )}
                </Td>
              </tr>
            ))}
          </Table>
        </Card>
      )}
      <InviteModal open={inviting} onClose={() => setInviting(false)} />
      <Confirm
        open={!!removing}
        onClose={() => setRemoving(null)}
        title={removing?.id === me?.id ? 'Leave this organization?' : `Remove ${removing?.email}?`}
        description="They lose access to its apps. API keys they own stop working here."
        action={removing?.id === me?.id ? 'Leave' : 'Remove'}
        loading={remove.isPending}
        onConfirm={() => remove.mutate(removing!.id, { onSuccess: () => setRemoving(null) })}
      />
    </>
  )
}

function InviteModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { current } = useOrg()
  const invite = useInvite(current?.organization.id ?? 0)
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<Role>('developer')
  useEffect(() => {
    if (open) {
      setEmail('')
      setRole('developer')
    }
  }, [open])
  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Invite a member"
      description="Existing accounts are added right away. Others get an invitation they accept after signing up with this email."
      footer={
        <Button variant="primary" loading={invite.isPending} disabled={!email.includes('@')} onClick={() => invite.mutate({ email: email.trim(), role }, { onSuccess: onClose })}>
          Invite
        </Button>
      }
    >
      <div className="space-y-4">
        <Input autoFocus label="Email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Select label="Role" value={role} onChange={(e) => setRole(e.target.value as Role)}>
          {roles.map((r) => (
            <option key={r} value={r}>
              {roleLabel[r]}: {roleHelp[r]}
            </option>
          ))}
        </Select>
      </div>
    </Modal>
  )
}

export function ApiKeysPage() {
  const { data: keys, isLoading } = useApiKeys()
  const { data: config } = useConfig()
  const create = useCreateApiKey()
  const revoke = useRevokeApiKey()
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const [created, setCreated] = useState<string | null>(null)
  const [revoking, setRevoking] = useState<{ id: number; name: string } | null>(null)
  return (
    <>
      <PageHeader
        title="API keys"
        description="Keys for the Shorebird CLI and CI. They act as you, in every organization you belong to."
        actions={
          <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setCreating(true)}>
            New key
          </Button>
        }
      />
      <Card>
        {isLoading ? (
          <Loading />
        ) : !keys?.length ? (
          <Empty icon={<KeyRound className="size-6" />} title="No API keys">
            Create one and set it as <code className="font-mono">SHOREBIRD_TOKEN</code>.
          </Empty>
        ) : (
          <Table head={['Name', 'Key', 'Created', 'Last used', '']}>
            {keys.map((k) => (
              <tr key={k.id}>
                <Td className="font-medium">{k.name}</Td>
                <Td className="font-mono text-[13px] text-muted">{k.prefix}…</Td>
                <Td className="text-[13px] text-muted">{date(k.created_at)}</Td>
                <Td className="text-[13px] text-muted">{timeAgo(k.last_used_at)}</Td>
                <Td className="text-right">
                  <Button variant="ghost" size="sm" icon={<Trash2 className="size-4" />} onClick={() => setRevoking(k)}>
                    Revoke
                  </Button>
                </Td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
      <Card className="mt-6 p-5">
        <p className="mb-2 text-sm font-medium">Use a key</p>
        <Code copy>{`export SHOREBIRD_TOKEN=sb_api_…\nexport SHOREBIRD_HOSTED_URL=${config?.api_base_url ?? window.location.origin}  # only needed before shorebird.yaml has base_url\nshorebird whoami`}</Code>
      </Card>
      <Modal
        open={creating}
        onClose={() => {
          setCreating(false)
          setCreated(null)
          setName('')
        }}
        title={created ? 'Copy your key' : 'New API key'}
        description={created ? "It won't be shown again." : 'Name it after where it will live, e.g. "GitHub Actions".'}
        footer={
          created ? (
            <Button
              variant="primary"
              onClick={() => {
                setCreating(false)
                setCreated(null)
                setName('')
              }}
            >
              Done
            </Button>
          ) : (
            <Button variant="primary" loading={create.isPending} disabled={!name.trim()} onClick={() => create.mutate({ name: name.trim() }, { onSuccess: (r) => setCreated(r.key) })}>
              Create key
            </Button>
          )
        }
      >
        {created ? (
          <div className="flex items-center gap-2 rounded-lg border border-line bg-panel-2 p-3">
            <code className="flex-1 font-mono text-[13px] break-all">{created}</code>
            <CopyButton value={created} />
          </div>
        ) : (
          <Input autoFocus label="Name" value={name} onChange={(e) => setName(e.target.value)} />
        )}
      </Modal>
      <Confirm
        open={!!revoking}
        onClose={() => setRevoking(null)}
        title={`Revoke "${revoking?.name}"?`}
        description="Anything using it stops working immediately."
        action="Revoke key"
        loading={revoke.isPending}
        onConfirm={() => revoke.mutate(revoking!.id, { onSuccess: () => setRevoking(null) })}
      />
    </>
  )
}

export function UsagePage() {
  const { current } = useOrg()
  const { data: usage, isLoading } = useUsage(current?.organization.id)
  const total = usage?.position.installs ?? 0
  return (
    <>
      <PageHeader title="Usage" description="Patch installs this calendar month. Self-hosted: no limits, no bill." />
      {isLoading || !usage ? (
        <Loading />
      ) : (
        <div className="space-y-6">
          <div className="grid gap-4 sm:grid-cols-3">
            <Stat label="Patch installs this month" value={num(total)} />
            <Stat label="Apps" value={num(usage.apps.length)} />
            <Stat label="Install limit" value="None" hint="Self-hosted" />
          </div>
          <Card>
            <CardHeader title="By app" />
            <div className="p-5">
              {usage.apps.length ? (
                <ShareBars
                  rows={[...usage.apps]
                    .sort((a, b) => b.patch_install_count - a.patch_install_count)
                    .map((a) => ({ label: a.name, value: a.patch_install_count, pct: total ? (a.patch_install_count * 100) / total : 0 }))}
                />
              ) : (
                <Empty title="No apps yet" />
              )}
            </div>
          </Card>
        </div>
      )}
    </>
  )
}

export function OrganizationPage() {
  const { current, isAdmin } = useOrg()
  const [name, setName] = useState(current?.organization.name ?? '')
  useEffect(() => setName(current?.organization.name ?? ''), [current])
  const rename = useRenameOrganization(current?.organization.id ?? 0)
  if (!current) return <Loading />
  return (
    <>
      <PageHeader title="Organization" description={`ID ${current.organization.id} · created ${date(current.organization.created_at)}`} />
      <Card>
        <CardHeader title="General" />
        <div className="flex flex-wrap items-end gap-3 p-5">
          <div className="min-w-64 flex-1">
            <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} disabled={!isAdmin} />
          </div>
          <Button variant="primary" disabled={!isAdmin || !name.trim() || name === current.organization.name} loading={rename.isPending} onClick={() => rename.mutate({ name: name.trim() })}>
            Save
          </Button>
        </div>
        <div className="border-t border-line px-5 py-4 text-[13px] text-muted">
          Type: <Badge>{current.organization.organization_type}</Badge> · Your role: <Badge tone="accent">{roleLabel[current.role]}</Badge>
          <span className="ml-2">
            <code className="font-mono">shorebird init --org-id {current.organization.id}</code> creates apps here.
          </span>
        </div>
      </Card>
    </>
  )
}

export function InvitationsPage() {
  const { data: invitations, isLoading } = useReceivedInvitations()
  const respond = useRespondInvitation()
  return (
    <>
      <PageHeader title="Invitations" description="Organizations that invited you" />
      <Card>
        {isLoading ? (
          <Loading />
        ) : !invitations?.length ? (
          <Empty icon={<Mail className="size-6" />} title="No pending invitations" />
        ) : (
          <div className="divide-y divide-line">
            {invitations.map((i) => (
              <div key={i.id} className="flex flex-wrap items-center gap-4 px-5 py-4">
                <Users className="size-5 text-faint" />
                <div className="flex-1">
                  <div className="font-medium">{i.target_name}</div>
                  <div className="text-[13px] text-muted">
                    {i.inviter_email || 'Someone'} invited you as {roleLabel[i.role]} · expires {date(i.expires_at)}
                  </div>
                </div>
                <Button variant="ghost" onClick={() => respond.mutate({ id: i.id, accept: false })}>
                  Decline
                </Button>
                <Button variant="primary" onClick={() => respond.mutate({ id: i.id, accept: true })}>
                  Accept
                </Button>
              </div>
            ))}
          </div>
        )}
      </Card>
    </>
  )
}

export function AccountPage() {
  const { data: me } = useMe()
  const [name, setName] = useState('')
  useEffect(() => setName(me?.display_name ?? ''), [me])
  const profile = useUpdateProfile()
  const password = useChangePassword()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  if (!me) return <Loading />
  return (
    <>
      <PageHeader title="Account" description={`${me.email} · member since ${date(me.created_at)}`} />
      <div className="space-y-6">
        <Card>
          <CardHeader title="Profile" />
          <div className="flex flex-wrap items-end gap-3 p-5">
            <div className="min-w-64 flex-1">
              <Input label="Display name" value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <Button variant="primary" loading={profile.isPending} disabled={name === (me.display_name ?? '')} onClick={() => profile.mutate({ display_name: name })}>
              Save
            </Button>
          </div>
        </Card>
        <Card>
          <CardHeader title="Password" />
          <form
            className="grid gap-4 p-5 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
            onSubmit={(e) => {
              e.preventDefault()
              password.mutate({ current_password: current, new_password: next }, { onSuccess: () => (setCurrent(''), setNext('')) })
            }}
          >
            {me.has_password && <Input label="Current password" type="password" value={current} onChange={(e) => setCurrent(e.target.value)} autoComplete="current-password" />}
            <Input label="New password" type="password" value={next} onChange={(e) => setNext(e.target.value)} hint="At least 10 characters." autoComplete="new-password" />
            <Button type="submit" variant="primary" loading={password.isPending} disabled={next.length < 10}>
              Update
            </Button>
          </form>
        </Card>
      </div>
    </>
  )
}

import { useMutation, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  api,
  c1,
  v1,
  type ApiKey,
  type AppMetadata,
  type AppSummary,
  type BuildRun,
  type Channel,
  type DeviceEvent,
  type Me,
  type Platform,
  type ReleaseArtifact,
  type ReleasePatch,
  type Role,
  type S,
} from './client'

// Session

export const useConfig = () =>
  useQuery({
    queryKey: ['config'],
    queryFn: () => api.get<{ signup_allowed: boolean; api_base_url: string }>(c1('/config')),
    staleTime: 60_000,
  })

export const useMe = () =>
  useQuery({
    queryKey: ['me'],
    queryFn: () => api.get<Me>(c1('/session')),
    retry: false,
    staleTime: 30_000,
  })

/// A mutation that invalidates [keys] and toasts [success] when it succeeds,
/// and toasts the server's message when it fails.
function useAction<TVars, TResult = unknown>(
  fn: (vars: TVars) => Promise<TResult>,
  opts: { keys?: QueryKey[]; success?: string | ((r: TResult, v: TVars) => string) } = {},
) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: fn,
    onSuccess: (result, vars) => {
      for (const key of opts.keys ?? []) qc.invalidateQueries({ queryKey: key })
      if (opts.success) toast.success(typeof opts.success === 'string' ? opts.success : opts.success(result, vars))
    },
    onError: (error: Error) => toast.error(error.message),
  })
}

export const useLogin = () =>
  useAction((v: { email: string; password: string }) => api.post<Me>(c1('/session'), v), { keys: [['me']] })

export const useSignup = () =>
  useAction((v: { email: string; password: string; name?: string }) => api.post<Me>(c1('/signup'), v), {
    keys: [['me']],
  })

export const useLogout = () => {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => api.del(c1('/session')),
    onSuccess: () => qc.clear(),
  })
}

export const useChangePassword = () =>
  useAction((v: { current_password: string; new_password: string }) => api.post(c1('/account/password'), v), {
    keys: [['me']],
    success: 'Password updated',
  })

export const useUpdateProfile = () =>
  useAction((v: { display_name: string }) => api.patch(v1('/users/me'), v), {
    keys: [['me']],
    success: 'Profile saved',
  })

// Organizations

export const useOrganizations = () =>
  useQuery({
    queryKey: ['orgs'],
    queryFn: () => api.get<S['GetOrganizationsResponse']>(v1('/organizations')).then((r) => r.organizations),
  })

export const useCreateOrganization = () =>
  useAction((v: { name: string }) => api.post<S['Organization']>(v1('/organizations'), v), {
    keys: [['orgs']],
    success: (o) => `Created ${o.name}`,
  })

export const useRenameOrganization = (orgId: number) =>
  useAction((v: { name: string }) => api.patch(v1(`/organizations/${orgId}`), v), {
    keys: [['orgs']],
    success: 'Organization renamed',
  })

export const useOrgUsers = (orgId?: number) =>
  useQuery({
    queryKey: ['org', orgId, 'users'],
    enabled: !!orgId,
    queryFn: () =>
      api.get<S['GetOrganizationUsersResponse']>(v1(`/organizations/${orgId}/users`)).then((r) => r.users),
  })

export const useOrgInvitations = (orgId?: number) =>
  useQuery({
    queryKey: ['org', orgId, 'invitations'],
    enabled: !!orgId,
    queryFn: () =>
      api.get<S['GetInvitationsResponse']>(v1(`/organizations/${orgId}/invitations`)).then((r) => r.invitations),
  })

export const useInvite = (orgId: number) =>
  useAction(
    (v: { email: string; role: Role }) =>
      api.post<{ type: 'invitation' | 'member'; email: string }>(v1(`/organizations/${orgId}/invitations`), v),
    {
      keys: [['org', orgId]],
      success: (r) => (r.type === 'member' ? `${r.email} added` : `Invitation created for ${r.email}`),
    },
  )

export const useRevokeInvitation = (orgId: number) =>
  useAction((id: string) => api.del(v1(`/organizations/${orgId}/invitations/${id}`)), {
    keys: [['org', orgId]],
    success: 'Invitation revoked',
  })

export const useSetMemberRole = (orgId: number) =>
  useAction((v: { userId: number; role: Role }) => api.patch(v1(`/organizations/${orgId}/users/${v.userId}`), { role: v.role }), {
    keys: [['org', orgId]],
    success: 'Role updated',
  })

export const useRemoveMember = (orgId: number) =>
  useAction((userId: number) => api.del(v1(`/organizations/${orgId}/users/${userId}`)), {
    keys: [['org', orgId], ['orgs']],
    success: 'Member removed',
  })

export const useReceivedInvitations = () =>
  useQuery({
    queryKey: ['invitations'],
    queryFn: () => api.get<S['GetReceivedInvitationsResponse']>(v1('/invitations')).then((r) => r.invitations),
  })

export const useRespondInvitation = () =>
  useAction((v: { id: string; accept: boolean }) => api.post(v1(`/invitations/${v.id}/${v.accept ? 'accept' : 'decline'}`)), {
    keys: [['invitations'], ['orgs'], ['me']],
    success: (_, v) => (v.accept ? 'Invitation accepted' : 'Invitation declined'),
  })

export const useUsage = (orgId?: number) =>
  useQuery({
    queryKey: ['org', orgId, 'usage'],
    enabled: !!orgId,
    queryFn: () => api.get<S['GetUsageResponse']>(v1(`/organizations/${orgId}/usage`)),
  })

// API keys

export const useApiKeys = () => useQuery({ queryKey: ['api-keys'], queryFn: () => api.get<ApiKey[]>(c1('/api-keys')) })

export const useCreateApiKey = () =>
  useAction((v: { name: string }) => api.post<{ name: string; key: string }>(c1('/api-keys'), v), {
    keys: [['api-keys']],
  })

export const useRevokeApiKey = () =>
  useAction((id: number) => api.del(c1(`/api-keys/${id}`)), { keys: [['api-keys']], success: 'Key revoked' })

// Apps

export const useOrgApps = (orgId?: number) =>
  useQuery({
    queryKey: ['org', orgId, 'apps'],
    enabled: !!orgId,
    queryFn: () => api.get<S['GetOrganizationAppsResponse']>(v1(`/organizations/${orgId}/apps`)).then((r) => r.apps),
  })

export const useApp = (appId: string) =>
  useQuery({ queryKey: ['app', appId], queryFn: () => api.get<AppMetadata>(v1(`/apps/${appId}`)) })

export const useCreateApp = () =>
  useAction((v: { display_name: string; organization_id: number }) => api.post<S['App']>(v1('/apps'), v), {
    keys: [['org']],
    success: (a) => `Created ${a.display_name}`,
  })

export const useRenameApp = (appId: string) =>
  useAction((v: { name: string }) => api.patch(v1(`/apps/${appId}`), v), {
    keys: [['app', appId], ['org']],
    success: 'App renamed',
  })

export const useDeleteApp = (appId: string) =>
  useAction(() => api.del(v1(`/apps/${appId}`)), { keys: [['org']], success: 'App deleted' })

export const useAppSummary = (appId: string) =>
  useQuery({ queryKey: ['app', appId, 'summary'], queryFn: () => api.get<AppSummary>(c1(`/apps/${appId}/summary`)) })

export const useSigningKey = (appId: string, enabled: boolean) =>
  useQuery({
    queryKey: ['app', appId, 'signing-key'],
    enabled,
    queryFn: () => api.get<S['GetSigningKeyResponse']>(v1(`/apps/${appId}/signing-key`)).then((r) => r.signing_key),
  })

export const useChannels = (appId: string) =>
  useQuery({ queryKey: ['app', appId, 'channels'], queryFn: () => api.get<Channel[]>(v1(`/apps/${appId}/channels`)) })

export const useCreateChannel = (appId: string) =>
  useAction((name: string) => api.post<Channel>(v1(`/apps/${appId}/channels`), { channel: name }), {
    keys: [['app', appId]],
    success: (c) => `Channel ${c.name} created`,
  })

export const useDeleteChannel = (appId: string) =>
  useAction((id: number) => api.del(v1(`/apps/${appId}/channels/${id}`)), {
    keys: [['app', appId]],
    success: 'Channel deleted',
  })

// Releases and patches

export const useReleases = (appId: string) =>
  useQuery({
    queryKey: ['app', appId, 'releases'],
    queryFn: () => api.get<S['GetReleasesResponse']>(v1(`/apps/${appId}/releases`)).then((r) => r.releases),
  })

export const useRelease = (appId: string, releaseId: number) =>
  useQuery({
    queryKey: ['app', appId, 'release', releaseId],
    queryFn: () => api.get<S['GetReleaseResponse']>(v1(`/apps/${appId}/releases/${releaseId}`)).then((r) => r.release),
  })

export const useUpdateRelease = (appId: string, releaseId: number) =>
  useAction((v: { notes?: string; status?: S['ReleaseStatus']; platform?: Platform }) =>
    api.patch(v1(`/apps/${appId}/releases/${releaseId}`), v),
  { keys: [['app', appId]], success: 'Release updated' })

export const useDeleteRelease = (appId: string) =>
  useAction((releaseId: number) => api.del(v1(`/apps/${appId}/releases/${releaseId}`)), {
    keys: [['app', appId]],
    success: 'Release deleted',
  })

export const useReleaseArtifacts = (appId: string, releaseId: number) =>
  useQuery({
    queryKey: ['app', appId, 'release', releaseId, 'artifacts'],
    queryFn: () =>
      api
        .get<S['GetReleaseArtifactsResponse']>(v1(`/apps/${appId}/releases/${releaseId}/artifacts`))
        .then((r) => r.artifacts as ReleaseArtifact[]),
  })

export const useDeleteReleasePlatform = (appId: string, releaseId: number) =>
  useAction(
    (platform: Platform) =>
      api.del(`${v1(`/apps/${appId}/releases/${releaseId}/artifacts`)}?platform=${platform}`),
    { keys: [['app', appId]], success: (_, p) => `Removed ${p} from the release` },
  )

export const usePatches = (appId: string, releaseId: number) =>
  useQuery({
    queryKey: ['app', appId, 'release', releaseId, 'patches'],
    queryFn: () =>
      api
        .get<S['GetReleasePatchesResponse']>(v1(`/apps/${appId}/releases/${releaseId}/patches`))
        .then((r) => r.patches as ReleasePatch[]),
  })

const patchPath = (appId: string, releaseId: number, patchId: number) =>
  v1(`/apps/${appId}/releases/${releaseId}/patches/${patchId}`)

export const usePromotePatch = (appId: string) =>
  useAction(
    (v: { patch_id: number; channel_id: number; rollout_percentage?: number }) =>
      api.post(v1(`/apps/${appId}/patches/promote`), v),
    { keys: [['app', appId]], success: 'Patch promoted' },
  )

export const useSetRollout = (appId: string, releaseId: number) =>
  useAction(
    (v: { patchId: number; pct: number }) =>
      api.put(`${patchPath(appId, releaseId, v.patchId)}/rollout`, { rollout_percentage: v.pct }),
    { keys: [['app', appId]], success: (_, v) => `Rollout set to ${v.pct}%` },
  )

export const useRollback = (appId: string, releaseId: number) =>
  useAction(
    (v: { patchId: number; rollback: boolean }) =>
      api.post(`${patchPath(appId, releaseId, v.patchId)}/${v.rollback ? 'rollback' : 'rollforward'}`),
    { keys: [['app', appId]], success: (_, v) => (v.rollback ? 'Patch rolled back' : 'Patch restored') },
  )

export const useUpdatePatchNotes = (appId: string, releaseId: number) =>
  useAction((v: { patchId: number; notes: string }) => api.patch(patchPath(appId, releaseId, v.patchId), { notes: v.notes }), {
    keys: [['app', appId]],
    success: 'Notes saved',
  })

// Activity

export const useBuildRuns = (appId: string) =>
  useQuery({ queryKey: ['app', appId, 'builds'], queryFn: () => api.get<BuildRun[]>(c1(`/apps/${appId}/build-runs`)) })

export const useEvents = (appId: string, type?: string) =>
  useQuery({
    queryKey: ['app', appId, 'events', type],
    queryFn: () => api.get<DeviceEvent[]>(c1(`/apps/${appId}/events`), { type, limit: 300 }),
    refetchInterval: 15_000,
  })

// Metrics (spec operations)

export type Range = { start: string; end: string; granularity: 'hour' | 'day' | 'week' }

export const useUniqueUsers = (appId: string, r: Range, groupBy?: 'platform' | 'release_version') =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'users', r, groupBy],
    queryFn: () =>
      api.get<S['GetUniqueUsersResponse']>(v1(`/apps/${appId}/metrics/unique-users`), { ...r, group_by: groupBy }),
  })

export const usePatchInstalls = (appId: string, r: Range, releaseId?: number) =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'installs', r, releaseId],
    queryFn: () =>
      api.get<S['GetPatchMetricResponse']>(
        v1(releaseId ? `/apps/${appId}/releases/${releaseId}/metrics/patch-installs` : `/apps/${appId}/metrics/patch-installs`),
        { ...r, group_by: releaseId ? 'patch' : 'release' },
      ),
  })

export const useVersionDistribution = (appId: string) =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'versions'],
    queryFn: () => api.get<S['GetVersionDistributionResponse']>(v1(`/apps/${appId}/metrics/version-distribution`)),
  })

export const useNewDevices = (appId: string) =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'new'],
    queryFn: () => api.get<S['GetNewDevicesResponse']>(v1(`/apps/${appId}/metrics/new-devices`)),
  })

export const useActiveHours = (appId: string) =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'hours'],
    queryFn: () => api.get<S['GetActiveHoursResponse']>(v1(`/apps/${appId}/metrics/active-hours`)),
  })

export const useHeatmap = (appId: string) =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'heatmap'],
    queryFn: () => api.get<S['GetActivityHeatmapResponse']>(v1(`/apps/${appId}/metrics/activity-heatmap`)),
  })

export const usePatchAdoption = (appId: string, releaseVersion: string | undefined, r: Range) =>
  useQuery({
    queryKey: ['app', appId, 'metrics', 'adoption', releaseVersion, r],
    enabled: !!releaseVersion,
    queryFn: () =>
      api.get<S['GetPatchAdoptionResponse']>(v1(`/apps/${appId}/metrics/patch-adoption`), {
        ...r,
        release_version: releaseVersion,
      }),
  })

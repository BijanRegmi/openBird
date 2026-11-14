import type { components } from './schema'

/// Protocol types, generated from protocol/openapi.yaml (bun run gen:api).
export type S = components['schemas']
export type AppMetadata = S['AppMetadata']
export type Release = S['Release']
export type ReleasePatch = S['ReleasePatch']
export type ReleaseArtifact = S['ReleaseArtifact']
export type Channel = S['Channel']
export type Platform = S['ReleasePlatform']
export type Role = S['Role']
export type OrganizationMembership = S['OrganizationMembership']
export type OrganizationUser = S['OrganizationUser']
export type InvitationSummary = S['InvitationSummary']
export type ReceivedInvitation = S['ReceivedInvitation']

/// Console-only shapes (server/lib/src/api/console_api.dart).
export type Me = {
  id: number
  email: string
  display_name: string | null
  created_at: string
  has_password: boolean
  pending_invitations: number
}
export type ApiKey = {
  id: number
  name: string
  prefix: string
  created_at: string
  last_used_at: string | null
}
export type BuildRun = {
  id: number
  run_id: string
  command: 'release' | 'patch'
  platform: Platform
  outcome: 'succeeded' | 'failed'
  reason?: string | null
  release_id?: number | null
  patch_id?: number | null
  duration_ms?: number | null
  dry_run?: boolean
  started_at?: string
  metadata?: Record<string, unknown> | null
  build_flags?: { dart_define_count: number; dart_defines: Record<string, string>; target?: string } | null
  created_at: string
}
export type DeviceEvent = {
  id: number
  type: string
  release_version: string
  patch_number: number
  platform: string
  arch: string
  message: string | null
  failure_category: string | null
  occurred_at: string
  client: string
}
export type AppSummary = {
  releases: number
  patches: number
  active_devices_30d: number
  active_devices_24h: number
  installs_30d: number
  failures_30d: number
  channels: number
}

export class ApiError extends Error {
  status: number
  code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

/// Every request carries the session cookie and the console header the
/// server requires on cookie-authenticated writes (CSRF protection).
export async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  query?: Record<string, string | number | boolean | undefined | null>,
): Promise<T> {
  const url = new URL(path, window.location.origin)
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v))
  }
  const res = await fetch(url, {
    method,
    credentials: 'same-origin',
    headers: {
      'x-openbird-console': '1',
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  })
  if (res.status === 204 || res.status === 304) return undefined as T
  const text = await res.text()
  const data = text ? safeJson(text) : undefined
  if (!res.ok) {
    const err = (data ?? {}) as { code?: string; message?: string }
    throw new ApiError(res.status, err.code ?? 'error', err.message ?? `Request failed (${res.status})`)
  }
  return data as T
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

export const api = {
  get: <T>(path: string, query?: Record<string, string | number | boolean | undefined | null>) =>
    request<T>('GET', path, undefined, query),
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, body ?? {}),
  patch: <T>(path: string, body?: unknown) => request<T>('PATCH', path, body ?? {}),
  put: <T>(path: string, body?: unknown) => request<T>('PUT', path, body ?? {}),
  del: <T>(path: string) => request<T>('DELETE', path),
}

/// Paths of the protocol routes, relative to the server origin.
export const v1 = (path: string) => `/api/v1${path}`
export const c1 = (path: string) => `/console/v1${path}`

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { OrganizationMembership } from '../api/client'
import { useOrganizations } from '../api/hooks'

type OrgState = {
  orgs: OrganizationMembership[]
  current?: OrganizationMembership
  setCurrent: (id: number) => void
  isAdmin: boolean
  canWrite: boolean
}

const OrgContext = createContext<OrgState>({ orgs: [], setCurrent: () => {}, isAdmin: false, canWrite: false })

const storageKey = 'org'

export function OrgProvider({ children }: { children: ReactNode }) {
  const { data: orgs = [] } = useOrganizations()
  const [id, setId] = useState<number | null>(() => {
    try {
      return Number(localStorage.getItem(storageKey)) || null
    } catch {
      return null
    }
  })
  const current = orgs.find((o) => o.organization.id === id) ?? orgs[0]
  useEffect(() => {
    if (current) {
      try {
        localStorage.setItem(storageKey, String(current.organization.id))
      } catch {
        /* per-viewer convenience only */
      }
    }
  }, [current])
  const value = useMemo<OrgState>(() => {
    const role = current?.role
    return {
      orgs,
      current,
      setCurrent: setId,
      isAdmin: role === 'owner' || role === 'admin',
      canWrite: role === 'owner' || role === 'admin' || role === 'appManager' || role === 'developer',
    }
  }, [orgs, current])
  return <OrgContext.Provider value={value}>{children}</OrgContext.Provider>
}

export const useOrg = () => useContext(OrgContext)

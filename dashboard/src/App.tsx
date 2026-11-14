import { lazy, Suspense } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'
import { useMe } from './api/hooks'
import { Layout } from './components/Layout'
import { Loading } from './components/ui'
import { OrgProvider } from './lib/org'
import { AppsPage } from './pages/Apps'
import { LoginPage } from './pages/Login'
import { AccountPage, ApiKeysPage, InvitationsPage, MembersPage, OrganizationPage, UsagePage } from './pages/OrgPages'

// The app pages carry the charts (recharts), so they load on demand.
const AppLayout = lazy(() => import('./pages/app/AppLayout').then((m) => ({ default: m.AppLayout })))
const OverviewPage = lazy(() => import('./pages/app/Overview').then((m) => ({ default: m.OverviewPage })))
const ReleasesPage = lazy(() => import('./pages/app/Releases').then((m) => ({ default: m.ReleasesPage })))
const ReleaseDetailPage = lazy(() => import('./pages/app/Releases').then((m) => ({ default: m.ReleaseDetailPage })))
const page = (name: 'ChannelsPage' | 'InsightsPage' | 'EventsPage' | 'BuildsPage' | 'AppSettingsPage') =>
  lazy(() => import('./pages/app/AppPages').then((m) => ({ default: m[name] })))
const ChannelsPage = page('ChannelsPage')
const InsightsPage = page('InsightsPage')
const EventsPage = page('EventsPage')
const BuildsPage = page('BuildsPage')
const AppSettingsPage = page('AppSettingsPage')

function RequireSession() {
  const { data: me, isLoading } = useMe()
  if (isLoading) return <Loading />
  if (!me) return <Navigate to="/login" replace />
  return (
    <OrgProvider>
      <Suspense fallback={<Loading />}>
        <Layout />
      </Suspense>
    </OrgProvider>
  )
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireSession />}>
        <Route index element={<Navigate to="/apps" replace />} />
        <Route path="apps" element={<AppsPage />} />
        <Route path="apps/:appId" element={<AppLayout />}>
          <Route index element={<OverviewPage />} />
          <Route path="releases" element={<ReleasesPage />} />
          <Route path="releases/:releaseId" element={<ReleaseDetailPage />} />
          <Route path="channels" element={<ChannelsPage />} />
          <Route path="insights" element={<InsightsPage />} />
          <Route path="events" element={<EventsPage />} />
          <Route path="builds" element={<BuildsPage />} />
          <Route path="settings" element={<AppSettingsPage />} />
        </Route>
        <Route path="members" element={<MembersPage />} />
        <Route path="api-keys" element={<ApiKeysPage />} />
        <Route path="usage" element={<UsagePage />} />
        <Route path="organization" element={<OrganizationPage />} />
        <Route path="invitations" element={<InvitationsPage />} />
        <Route path="account" element={<AccountPage />} />
        <Route path="*" element={<Navigate to="/apps" replace />} />
      </Route>
    </Routes>
  )
}

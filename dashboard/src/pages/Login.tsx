import { ArrowRight, ShieldCheck, Smartphone, Zap } from 'lucide-react'
import { useState } from 'react'
import { Navigate, useNavigate, useSearchParams } from 'react-router-dom'
import { useConfig, useLogin, useMe, useSignup } from '../api/hooks'
import { Logo } from '../components/Layout'
import { Button, Input } from '../components/ui'

export function LoginPage() {
  const { data: me } = useMe()
  const { data: config } = useConfig()
  const [params] = useSearchParams()
  const [mode, setMode] = useState<'login' | 'signup'>(params.get('signup') ? 'signup' : 'login')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [name, setName] = useState('')
  const login = useLogin()
  const signup = useSignup()
  const navigate = useNavigate()
  if (me) return <Navigate to="/apps" replace />

  const submit = (e: { preventDefault(): void }) => {
    e.preventDefault()
    const done = { onSuccess: () => navigate('/apps') }
    if (mode === 'login') login.mutate({ email, password }, done)
    else signup.mutate({ email, password, name }, done)
  }

  return (
    <div className="grid min-h-full lg:grid-cols-2">
      <div className="flex flex-col justify-center px-6 py-12 sm:px-12">
        <div className="mx-auto w-full max-w-sm">
          <Logo className="mb-10" />
          <h1 className="text-2xl font-semibold tracking-tight">{mode === 'login' ? 'Sign in' : 'Create your account'}</h1>
          <p className="mt-1.5 text-sm text-muted">
            {mode === 'login' ? 'Manage releases, patches and rollouts.' : 'Your account gets a personal organization for its apps.'}
          </p>
          <form onSubmit={submit} className="mt-8 space-y-4">
            {mode === 'signup' && <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" />}
            <Input label="Email" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" autoFocus />
            <Input
              label="Password"
              type="password"
              required
              minLength={mode === 'signup' ? 10 : undefined}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              hint={mode === 'signup' ? 'At least 10 characters.' : undefined}
            />
            <Button type="submit" variant="primary" className="w-full" loading={login.isPending || signup.isPending}>
              {mode === 'login' ? 'Sign in' : 'Create account'} <ArrowRight className="size-4" />
            </Button>
          </form>
          <p className="mt-6 text-center text-[13px] text-muted">
            {mode === 'login' ? (
              config?.signup_allowed ? (
                <>
                  New here?{' '}
                  <button className="font-medium text-accent hover:underline" onClick={() => setMode('signup')}>
                    Create an account
                  </button>
                </>
              ) : (
                <>
                  Invited?{' '}
                  <button className="font-medium text-accent hover:underline" onClick={() => setMode('signup')}>
                    Sign up with the invited email
                  </button>
                </>
              )
            ) : (
              <>
                Have an account?{' '}
                <button className="font-medium text-accent hover:underline" onClick={() => setMode('login')}>
                  Sign in
                </button>
              </>
            )}
          </p>
        </div>
      </div>
      <div className="relative hidden overflow-hidden border-l border-line bg-panel lg:block">
        <div
          className="absolute inset-0 opacity-60"
          style={{
            background:
              'radial-gradient(60% 50% at 70% 20%, color-mix(in oklab, var(--accent) 22%, transparent), transparent), radial-gradient(50% 50% at 20% 90%, color-mix(in oklab, var(--chart-2) 18%, transparent), transparent)',
          }}
        />
        <div className="relative flex h-full flex-col justify-center px-16">
          <h2 className="max-w-md text-3xl font-semibold tracking-tight">Ship Flutter fixes in minutes, on your own infrastructure.</h2>
          <ul className="mt-10 space-y-6">
            {[
              { icon: Zap, title: 'Over-the-air patches', body: 'Use the stock Shorebird CLI. Patches download in the background and apply on the next launch.' },
              { icon: ShieldCheck, title: 'Signed by default', body: 'Every patch is signed with your organization’s key. Devices refuse anything else.' },
              { icon: Smartphone, title: 'Staged rollouts', body: 'Roll out to a percentage of installs, watch adoption, roll back in one click.' },
            ].map(({ icon: Icon, title, body }) => (
              <li key={title} className="flex gap-4">
                <div className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-accent-soft text-accent">
                  <Icon className="size-4.5" />
                </div>
                <div>
                  <p className="font-medium">{title}</p>
                  <p className="mt-0.5 text-sm text-muted">{body}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  )
}

import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import Login from './components/Login'
import RequestForm from './components/RequestForm'
import MyRequests from './components/MyRequests'
import Validation from './components/Validation'

export default function App() {
  const [session, setSession] = useState(null)
  const [role, setRole] = useState(null)
  const [refreshKey, setRefreshKey] = useState(0)
  const refresh = () => setRefreshKey(k => k + 1)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) { setRole(null); return }
    supabase.from('profiles').select('role').eq('id', session.user.id).single()
      .then(({ data }) => setRole(data?.role))
  }, [session])

  if (!session) return <Login />

  return (
    <div>
      <p>
        Connecté : {session.user.email} ({role})
        <button onClick={() => supabase.auth.signOut()}>Déconnexion</button>
      </p>
      <RequestForm userId={session.user.id} onCreated={refresh} />
      {['manager', 'hr', 'drh'].includes(role) && (
        <Validation profile={{ id: session.user.id, role }} />
      )}
      <MyRequests refreshKey={refreshKey} />
    </div>
  )
}

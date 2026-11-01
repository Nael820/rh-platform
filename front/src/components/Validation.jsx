// src/components/Validation.jsx — validation via RPC (les UPDATE directs sont bloqués par la RLS)
// Adapter l'import ci-dessous au chemin de ton client Supabase.
import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

const LEVEL = { manager: 'Manager', hr: 'RH', drh: 'DRH' }
const STAGE = { pending: 'manager', manager_review: 'manager', hr_review: 'hr', drh_review: 'drh' }

export default function Validation({ profile }) {
  const [rows, setRows] = useState([])
  const [err, setErr] = useState(null)

  async function load() {
    const { data, error } = await supabase
      .from('requests')
      .select('*, request_types(name), profiles!requests_requester_id_fkey(full_name), ai_reviews(verdict, summary, created_at)')
      .in('status', ['pending', 'manager_review', 'hr_review', 'drh_review'])
      .order('created_at', { ascending: false })
    if (error) setErr(error.message)
    else setRows(data)
  }

  useEffect(() => {
    load()
    const ch = supabase.channel('validation')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'requests' }, load)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'ai_reviews' }, load)
      .subscribe()
    return () => supabase.removeChannel(ch)
  }, [])

  // Une ligne n'est actionnable que si ce profil correspond à l'étape en cours
  const canAct = (r) => {
    const stage = STAGE[r.status]
    if (r.requester_id === profile.id) return false
    if (stage === 'manager') return profile.role === 'manager'
    if (stage === 'hr') return ['hr', 'drh'].includes(profile.role)
    if (stage === 'drh') return profile.role === 'drh'
    return false
  }

  async function approve(r) {
    const { error } = await supabase.rpc('approve_request', { p_request: r.id, p_comment: null })
    if (error) setErr(error.message); else load()
  }
  async function reject(r) {
    const motif = window.prompt('Motif du refus (obligatoire) :')
    if (!motif || !motif.trim()) return
    const { error } = await supabase.rpc('reject_request', { p_request: r.id, p_comment: motif })
    if (error) setErr(error.message); else load()
  }

  return (
    <div>
      <h2>Demandes à valider</h2>
      {err && <p style={{ color: 'crimson' }}>{err}</p>}
      {rows.length === 0 && <p>Rien à valider.</p>}
      {rows.map((r) => {
        const ai = r.ai_reviews?.[0]
        return (
          <div key={r.id} style={{ border: '1px solid #ddd', borderRadius: 8, padding: 12, margin: '8px 0' }}>
            <strong>{r.request_types?.name}</strong> — {r.profiles?.full_name}
            <div>
              {r.start_date && <>Du {r.start_date} au {r.end_date} ({r.days_requested} j) </>}
              {r.amount != null && <>{r.amount} € </>}
              · Niveau requis : <b>{LEVEL[r.required_level]}</b> · Étape : {r.status}
            </div>
            {r.reason && <div>Motif : {r.reason}</div>}
            {ai && (
              <div style={{ background: ai.verdict === 'ok' ? '#e8f7ee' : '#fff4e0', padding: 8, marginTop: 6, borderRadius: 6 }}>
                🤖 Contrôle IA : <b>{ai.verdict === 'ok' ? 'RAS' : 'À vérifier'}</b> — {ai.summary}
              </div>
            )}
            {canAct(r) && (
              <div style={{ marginTop: 8 }}>
                <button onClick={() => approve(r)}>Approuver</button>{' '}
                <button onClick={() => reject(r)}>Refuser</button>
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

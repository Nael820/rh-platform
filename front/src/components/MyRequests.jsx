import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export default function MyRequests({ refreshKey }) {
  const [requests, setRequests] = useState([])

  useEffect(() => {
    supabase
      .from('requests')
      .select('id, status, start_date, end_date, amount, created_at, request_types(label)')
      .order('created_at', { ascending: false })
      .then(({ data }) => setRequests(data || []))
  }, [refreshKey])

  return (
    <section>
      <h2>Demandes</h2>
      <table>
        <thead>
          <tr><th>Type</th><th>Début</th><th>Fin</th><th>Montant</th><th>Statut</th></tr>
        </thead>
        <tbody>
          {requests.map(r => (
            <tr key={r.id}>
              <td>{r.request_types?.label}</td>
              <td>{r.start_date}</td>
              <td>{r.end_date}</td>
              <td>{r.amount}</td>
              <td>{r.status}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

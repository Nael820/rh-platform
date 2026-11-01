import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export default function RequestForm({ userId, onCreated }) {
  const [types, setTypes] = useState([])
  const [form, setForm] = useState({ type_id: '', start_date: '', end_date: '', amount: '', comment: '' })
  const [msg, setMsg] = useState('')

  useEffect(() => {
    supabase.from('request_types').select('id, label').then(({ data }) => setTypes(data || []))
  }, [])

  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value })

  async function submit() {
    const { error } = await supabase.from('requests').insert({
      requester_id: userId,
      type_id: Number(form.type_id),
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      amount: form.amount ? Number(form.amount) : null,
      comment: form.comment,
    })
    setMsg(error ? error.message : 'Demande envoyée !')
    if (!error) onCreated()
  }

  return (
    <section>
      <h2>Nouvelle demande</h2>
      <select value={form.type_id} onChange={set('type_id')}>
        <option value="">Type de demande</option>
        {types.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
      </select>
      <input type="date" value={form.start_date} onChange={set('start_date')} />
      <input type="date" value={form.end_date} onChange={set('end_date')} />
      <input type="number" placeholder="Montant (matériel/formation)" value={form.amount} onChange={set('amount')} />
      <textarea placeholder="Commentaire" value={form.comment} onChange={set('comment')} />
      <button onClick={submit}>Envoyer</button>
      <p>{msg}</p>
    </section>
  )
}

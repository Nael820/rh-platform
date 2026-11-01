# Workflows n8n
Exporter chaque workflow depuis n8n (menu ⋯ → Download) et déposer le .json ici.
Ne jamais committer de clés : les credentials restent dans n8n.
Flux IA : Webhook → HTTP `rpc/check_request` → LLM (Gemini) → HTTP `rpc/ai_record_review`.

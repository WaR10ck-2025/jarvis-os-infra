# K8s Secrets Management

Secrets werden NICHT im Git gespeichert. Sie muessen manuell auf dem Cluster erstellt werden.

## Aktuelle Secrets (jarvis-apps Namespace)

| Secret | Keys | Service |
|--------|------|---------|
| `n8n-secrets` | `N8N_ENCRYPTION_KEY` | n8n StatefulSet |
| `deployment-hub-secrets` | `HUB_API_TOKEN`, `ADMIN_API_TOKEN`, `HUB_SECRET_KEY`, `HUB_WEBHOOK_SECRET`, `DATABASE_URL`, `HARDWARE_KEY_MODE`, `HUB_HOST`, `HUB_PORT`, `HUB_RP_ID` | deployment-hub |
| `voice-assistant-secrets` | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `LLM_PROVIDER`, `OPENAI_MODEL`, `ANTHROPIC_MODEL`, `SERVER_HOST`, `SERVER_PORT`, `TTS_MODEL`, `TTS_VOICE`, `WHISPER_LANGUAGE`, `WHISPER_MODEL_SIZE` | voice-assistant |
| `pionex-mcp-secrets` | `PIONEX_API_KEY`, `PIONEX_SECRET_KEY` | pionex-mcp |

## Secrets erstellen (Beispiel)

```bash
kubectl create secret generic n8n-secrets -n jarvis-apps \
  --from-literal=N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
```

## Registry-Auth

ghcr.io Zugang wird ueber `/etc/rancher/k3s/registries.yaml` auf dem k3s-Node konfiguriert (PAT mit `read:packages` Scope).

## Spaeter: Sealed Secrets oder External Secrets Operator

Fuer GitOps (ArgoCD) koennen Secrets mit Sealed Secrets verschluesselt im Git gespeichert werden:
```bash
kubeseal --format yaml < secret.yaml > sealed-secret.yaml
```

# J.A.R.V.I.S-OS Helm Charts

## Charts

| Chart | Typ | Beschreibung |
|-------|-----|-------------|
| `jarvis-app` | Generisch | Websites + FastAPI Services (Deployment) |
| `jarvis-n8n` | Spezifisch | n8n Workflow Automation (StatefulSet) |
| `jarvis-headscale` | Spezifisch | Headscale VPN Server (StatefulSet) |

## Deployment

### Website deployen (Beispiel sv-niederklein)

```bash
helm install sv-niederklein ./jarvis-app \
  -f values/sv-niederklein.yaml \
  -n jarvis-apps
```

### FastAPI Service deployen (Beispiel deployment-hub)

```bash
# Erst Secret erstellen (manuell, nicht im Chart)
kubectl create secret generic deployment-hub-secrets -n jarvis-apps \
  --from-literal=HUB_API_TOKEN=$(openssl rand -hex 32) \
  --from-literal=ADMIN_API_TOKEN=$(openssl rand -hex 32) \
  --from-literal=HUB_SECRET_KEY=$(openssl rand -hex 32)

# Dann Chart installieren
helm install deployment-hub ./jarvis-app \
  -f values/deployment-hub.yaml \
  -n jarvis-apps
```

### n8n deployen

```bash
kubectl create secret generic n8n-secrets -n jarvis-apps \
  --from-literal=N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

helm install n8n ./jarvis-n8n -n jarvis-apps
```

### Headscale deployen

```bash
helm install headscale ./jarvis-headscale -n jarvis-infra
```

## Upgrade

```bash
helm upgrade sv-niederklein ./jarvis-app -f values/sv-niederklein.yaml -n jarvis-apps
```

## Alle Services auf einmal

```bash
for site in sv-niederklein schuetzenverein ich-ag; do
  helm install $site ./jarvis-app -f values/$site.yaml -n jarvis-apps
done

for svc in pionex-mcp voice-assistant deployment-hub; do
  helm install $svc ./jarvis-app -f values/$svc.yaml -n jarvis-apps
done

helm install n8n ./jarvis-n8n -n jarvis-apps
helm install headscale ./jarvis-headscale -n jarvis-infra
```

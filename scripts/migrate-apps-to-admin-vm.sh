#!/bin/bash
# migrate-apps-to-admin-vm.sh — Migriert Apps von VM 500 → Admin-VM
#
# Erstellt JarvisApp CRDs fuer alle bestehenden Workloads auf der Admin-VM.
# Die Container-Images bleiben identisch (ghcr.io/war10ck-2025/*).
#
# Ausfuehren auf der Admin-VM (192.168.10.155) oder via SSH.
# Verwendung: bash scripts/migrate-apps-to-admin-vm.sh
set -eo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Migriere Workloads → Admin-VM ==="
echo ""

# ── Websites ────────────────────────────────────────────────────────────────
echo "[1/3] Websites deployen..."

kubectl apply -f - << 'EOF'
apiVersion: jarvis-os.io/v1
kind: JarvisApp
metadata:
  name: sv-niederklein
  namespace: default
spec:
  appId: SV-Niederklein
  image: ghcr.io/war10ck-2025/sv-niederklein-website:latest
  port: 80
  ingress:
    enabled: true
    host: sv-niederklein.jarvis.local
  resources:
    requests: { memory: "32Mi", cpu: "25m" }
    limits: { memory: "128Mi", cpu: "250m" }
  persistence:
    enabled: false
---
apiVersion: jarvis-os.io/v1
kind: JarvisApp
metadata:
  name: schuetzenverein
  namespace: default
spec:
  appId: Schuetzenverein
  image: ghcr.io/war10ck-2025/schuetzenverein-niederklein-website:latest
  port: 80
  ingress:
    enabled: true
    host: schuetzenverein.jarvis.local
  resources:
    requests: { memory: "32Mi", cpu: "25m" }
    limits: { memory: "128Mi", cpu: "250m" }
  persistence:
    enabled: false
---
apiVersion: jarvis-os.io/v1
kind: JarvisApp
metadata:
  name: ich-ag
  namespace: default
spec:
  appId: Ich-AG
  image: ghcr.io/war10ck-2025/ich-ag-website:latest
  port: 80
  ingress:
    enabled: true
    host: ich-ag.jarvis.local
  resources:
    requests: { memory: "32Mi", cpu: "25m" }
    limits: { memory: "128Mi", cpu: "250m" }
  persistence:
    enabled: false
EOF

echo "  ✓ 3 Websites deployed"

# ── FastAPI Services ────────────────────────────────────────────────────────
echo "[2/3] FastAPI-Services deployen..."

kubectl apply -f - << 'EOF'
apiVersion: jarvis-os.io/v1
kind: JarvisApp
metadata:
  name: pionex-mcp
  namespace: default
spec:
  appId: Pionex-MCP
  image: ghcr.io/war10ck-2025/pionex-mcp-server:latest
  port: 8000
  ingress:
    enabled: true
    host: pionex-mcp.jarvis.local
  resources:
    requests: { memory: "64Mi", cpu: "50m" }
    limits: { memory: "256Mi", cpu: "500m" }
  persistence:
    enabled: false
---
apiVersion: jarvis-os.io/v1
kind: JarvisApp
metadata:
  name: voice-assistant
  namespace: default
spec:
  appId: Voice-Assistant
  image: ghcr.io/war10ck-2025/ki-voice-asistent:latest
  port: 8000
  ingress:
    enabled: true
    host: voice-assistant.jarvis.local
  resources:
    requests: { memory: "128Mi", cpu: "100m" }
    limits: { memory: "512Mi", cpu: "1" }
  persistence:
    enabled: false
---
apiVersion: jarvis-os.io/v1
kind: JarvisApp
metadata:
  name: deployment-hub
  namespace: default
spec:
  appId: Deployment-Hub
  image: ghcr.io/war10ck-2025/github-deployment-connector:latest
  port: 8000
  ingress:
    enabled: true
    host: deploy.jarvis.local
  resources:
    requests: { memory: "64Mi", cpu: "50m" }
    limits: { memory: "256Mi", cpu: "500m" }
  persistence:
    enabled: true
    size: "2Gi"
    mountPath: /app/data
EOF

echo "  ✓ 3 FastAPI-Services deployed"

# ── Status pruefen ──────────────────────────────────────────────────────────
echo ""
echo "[3/3] Status pruefen..."
sleep 5
kubectl get jarvisapps -o wide

echo ""
echo "=== Migration abgeschlossen ==="
echo ""
echo "NPM-Routen aktualisieren (auf LXC 10):"
echo "  sv-niederklein.jarvis.local    → 192.168.10.155:30080"
echo "  schuetzenverein.jarvis.local   → 192.168.10.155:30080"
echo "  ich-ag.jarvis.local            → 192.168.10.155:30080"
echo "  pionex-mcp.jarvis.local        → 192.168.10.155:30080"
echo "  voice-assistant.jarvis.local   → 192.168.10.155:30080"
echo "  deploy.jarvis.local            → 192.168.10.155:30080"
echo ""
echo "HINWEIS: K8s-Secrets fuer Services manuell migrieren:"
echo "  kubectl create secret generic pionex-secrets \\"
echo "    --from-literal=PIONEX_API_KEY=... \\"
echo "    --from-literal=PIONEX_SECRET_KEY=..."
echo ""

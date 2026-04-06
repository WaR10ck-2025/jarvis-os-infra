"""
J.A.R.V.I.S-OS Kubernetes Operator (Per-VM Version)

Laeuft in jeder User-VM (und Admin-VM) als lokaler Operator.
Reconciled JarvisApp Custom Resources — deployed Apps als Container oder Helm Charts.

Aenderungen gegenueber Shared-K8s-Version:
  - JarvisTenant ENTFERNT (VMs ersetzen Namespaces, Proxmox verwaltet User)
  - Hardware-Profile ENTFERNT (Profile sind jetzt Proxmox-VM-Sizing im Admin-Service)
  - Kapazitaetspruefung ENTFERNT (VM-Limits durch Proxmox enforced)
  - Katalog-Sync NEU (laedt App-Katalog periodisch vom Admin-Service)
  - Status-Report NEU (meldet App-Status + Ressourcen an Admin-Service)
"""

import datetime
import json
import os
import kopf
import kubernetes
import logging
import subprocess
import tempfile
import yaml

logger = logging.getLogger("jarvis-operator")

# ---------------------------------------------------------------------------
# Konfiguration (aus Umgebungsvariablen / ConfigMap)
# ---------------------------------------------------------------------------

ADMIN_SERVICE_URL = os.getenv("ADMIN_SERVICE_URL", "http://192.168.10.160:8300")
VM_USERNAME = os.getenv("VM_USERNAME", "unknown")
VM_MODE = os.getenv("VM_MODE", "user")  # "user" oder "admin"
CATALOG_PATH = os.getenv("CATALOG_PATH", "/opt/jarvis/catalog.json")
APPS_NAMESPACE = os.getenv("APPS_NAMESPACE", "default")  # Apps landen hier


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    settings.posting.level = logging.WARNING
    settings.persistence.finalizer = "jarvis-os.io/finalizer"
    settings.persistence.progress_storage = kopf.AnnotationsProgressStorage(
        prefix="jarvis-os.io"
    )
    # K8s-Client initialisieren
    try:
        kubernetes.config.load_incluster_config()
    except kubernetes.config.ConfigException:
        kubeconfig = os.environ.get("KUBECONFIG", os.path.expanduser("~/.kube/config"))
        kubernetes.config.load_kube_config(config_file=kubeconfig)

    logger.info(
        "J.A.R.V.I.S-OS Operator gestartet — User: %s, Modus: %s, Admin-Service: %s",
        VM_USERNAME, VM_MODE, ADMIN_SERVICE_URL,
    )


# ---------------------------------------------------------------------------
# Katalog-Sync (Periodisch vom Admin-Service laden)
# ---------------------------------------------------------------------------

@kopf.timer("jarvis-os.io", "v1", "jarvisapps", interval=3600, initial_delay=30, idle=3600)
def catalog_sync(**_):
    """Synchronisiert den App-Katalog vom Admin-Service (stuendlich)."""
    import urllib.request
    try:
        url = f"{ADMIN_SERVICE_URL}/api/v1/catalog"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
        with open(CATALOG_PATH, "w") as f:
            json.dump(data, f, indent=2)
        logger.info("Katalog synchronisiert: %d Apps", len(data))
    except Exception as e:
        logger.warning("Katalog-Sync fehlgeschlagen: %s", e)


# ---------------------------------------------------------------------------
# Status-Report (Periodisch an Admin-Service melden)
# ---------------------------------------------------------------------------

@kopf.timer("jarvis-os.io", "v1", "jarvisapps", interval=300, initial_delay=60, idle=300)
def status_report(**_):
    """Meldet App-Status + Ressourcennutzung an den Admin-Service."""
    import urllib.request
    try:
        # Aktuelle Apps zaehlen
        custom_api = kubernetes.client.CustomObjectsApi()
        try:
            apps = custom_api.list_namespaced_custom_object(
                "jarvis-os.io", "v1", APPS_NAMESPACE, "jarvisapps"
            )
            app_count = len(apps.get("items", []))
            app_names = [a["spec"]["appId"] for a in apps.get("items", [])]
        except kubernetes.client.exceptions.ApiException:
            app_count = 0
            app_names = []

        payload = json.dumps({
            "username": VM_USERNAME,
            "app_count": app_count,
            "apps": app_names,
            "mode": VM_MODE,
        }).encode()

        url = f"{ADMIN_SERVICE_URL}/api/v1/users/{VM_USERNAME}/heartbeat"
        req = urllib.request.Request(url, data=payload, method="POST",
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10)
        logger.debug("Status-Report gesendet: %d Apps", app_count)
    except Exception as e:
        logger.debug("Status-Report fehlgeschlagen (nicht kritisch): %s", e)


# ---------------------------------------------------------------------------
# JarvisApp — Create
# ---------------------------------------------------------------------------

@kopf.on.create("jarvis-os.io", "v1", "jarvisapps")
def app_create(spec, name, namespace, patch, **_):
    app_id = spec["appId"]
    logger.info("Deploye App '%s' in Namespace '%s'", app_id, namespace)

    image = spec.get("image")
    helm_chart = spec.get("helmChart")
    port = spec.get("port", 8080)

    if image:
        _deploy_container(namespace, name, app_id, image, port, spec, patch)
    elif helm_chart:
        _deploy_helm(namespace, name, app_id, helm_chart, spec, patch)
    else:
        patch.status["phase"] = "Error"
        patch.status["message"] = "Entweder 'image' oder 'helmChart' muss angegeben werden"
        return


# ---------------------------------------------------------------------------
# JarvisApp — Delete
# ---------------------------------------------------------------------------

@kopf.on.delete("jarvis-os.io", "v1", "jarvisapps")
def app_delete(spec, name, namespace, **_):
    app_id = spec["appId"]
    helm_chart = spec.get("helmChart")
    logger.info("Loesche App '%s' aus Namespace '%s'", app_id, namespace)

    if helm_chart:
        _uninstall_helm(namespace, name, app_id)
    else:
        apps_api = kubernetes.client.AppsV1Api()
        api = kubernetes.client.CoreV1Api()
        net_api = kubernetes.client.NetworkingV1Api()

        _safe_delete(lambda: apps_api.delete_namespaced_deployment(name, namespace))
        _safe_delete(lambda: api.delete_namespaced_service(name, namespace))
        _safe_delete(lambda: net_api.delete_namespaced_ingress(name, namespace))
        _safe_delete(lambda: api.delete_namespaced_persistent_volume_claim(f"{name}-data", namespace))

    logger.info("App '%s' aus '%s' entfernt", app_id, namespace)


# ---------------------------------------------------------------------------
# Container-Deployment
# ---------------------------------------------------------------------------

def _deploy_container(namespace, name, app_id, image, port, spec, patch):
    """Erstellt Deployment + Service + Ingress fuer eine Container-App."""
    apps_api = kubernetes.client.AppsV1Api()
    api = kubernetes.client.CoreV1Api()
    net_api = kubernetes.client.NetworkingV1Api()

    labels = {
        "app": name,
        "app.kubernetes.io/name": app_id.lower(),
        "app.kubernetes.io/managed-by": "jarvis-operator",
        "app.kubernetes.io/part-of": "jarvis-os",
    }

    # Resource Limits
    res_spec = spec.get("resources", {})
    requests = res_spec.get("requests", {})
    limits = res_spec.get("limits", {})
    resources = kubernetes.client.V1ResourceRequirements(
        requests={
            "memory": requests.get("memory", "64Mi"),
            "cpu": requests.get("cpu", "50m"),
        },
        limits={
            "memory": limits.get("memory", "512Mi"),
            "cpu": limits.get("cpu", "1"),
        },
    )

    # Volume Mounts (optional)
    volumes = []
    volume_mounts = []
    persistence = spec.get("persistence", {})
    if persistence.get("enabled", False):
        pvc_name = f"{name}-data"
        mount_path = persistence.get("mountPath", "/data")
        size = persistence.get("size", "5Gi")

        pvc = kubernetes.client.V1PersistentVolumeClaim(
            metadata=kubernetes.client.V1ObjectMeta(
                name=pvc_name, namespace=namespace, labels=labels
            ),
            spec=kubernetes.client.V1PersistentVolumeClaimSpec(
                access_modes=["ReadWriteOnce"],
                resources=kubernetes.client.V1VolumeResourceRequirements(
                    requests={"storage": size}
                ),
            ),
        )
        _apply_resource(api.create_namespaced_persistent_volume_claim, namespace, pvc)

        volumes.append(
            kubernetes.client.V1Volume(
                name="app-data",
                persistent_volume_claim=kubernetes.client.V1PersistentVolumeClaimVolumeSource(
                    claim_name=pvc_name
                ),
            )
        )
        volume_mounts.append(
            kubernetes.client.V1VolumeMount(name="app-data", mount_path=mount_path)
        )

    # Deployment
    deployment = kubernetes.client.V1Deployment(
        metadata=kubernetes.client.V1ObjectMeta(
            name=name, namespace=namespace, labels=labels
        ),
        spec=kubernetes.client.V1DeploymentSpec(
            replicas=1,
            selector=kubernetes.client.V1LabelSelector(match_labels={"app": name}),
            template=kubernetes.client.V1PodTemplateSpec(
                metadata=kubernetes.client.V1ObjectMeta(labels=labels),
                spec=kubernetes.client.V1PodSpec(
                    containers=[
                        kubernetes.client.V1Container(
                            name=app_id.lower(),
                            image=image,
                            ports=[
                                kubernetes.client.V1ContainerPort(
                                    container_port=port, name="http"
                                )
                            ],
                            resources=resources,
                            volume_mounts=volume_mounts or None,
                        )
                    ],
                    volumes=volumes or None,
                ),
            ),
        ),
    )
    _apply_resource(apps_api.create_namespaced_deployment, namespace, deployment)

    # Service
    svc = kubernetes.client.V1Service(
        metadata=kubernetes.client.V1ObjectMeta(
            name=name, namespace=namespace, labels=labels
        ),
        spec=kubernetes.client.V1ServiceSpec(
            selector={"app": name},
            ports=[
                kubernetes.client.V1ServicePort(
                    port=port, target_port="http", name="http"
                )
            ],
        ),
    )
    _apply_resource(api.create_namespaced_service, namespace, svc)

    # Ingress
    ingress_spec = spec.get("ingress", {})
    if ingress_spec.get("enabled", True):
        host = ingress_spec.get(
            "host", f"{app_id.lower()}.{namespace}.k8s.jarvis.local"
        )
        ingress = {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "Ingress",
            "metadata": {"name": name, "namespace": namespace, "labels": labels},
            "spec": {
                "ingressClassName": "nginx",
                "rules": [
                    {
                        "host": host,
                        "http": {
                            "paths": [
                                {
                                    "path": "/",
                                    "pathType": "Prefix",
                                    "backend": {
                                        "service": {
                                            "name": name,
                                            "port": {"number": port},
                                        }
                                    },
                                }
                            ]
                        },
                    }
                ],
            },
        }
        try:
            net_api.create_namespaced_ingress(namespace, ingress)
        except kubernetes.client.exceptions.ApiException as e:
            if e.status != 409:
                raise
        endpoint = f"http://{host}"
    else:
        endpoint = f"{name}.{namespace}.svc.cluster.local:{port}"

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    patch.status["phase"] = "Running"
    patch.status["endpoint"] = endpoint
    patch.status["message"] = f"App '{app_id}' deployed"
    patch.status["lastUpdated"] = now

    logger.info("App '%s' laeuft unter %s", app_id, endpoint)


# ---------------------------------------------------------------------------
# Helm-Deployment
# ---------------------------------------------------------------------------

def _deploy_helm(namespace, name, app_id, helm_chart, spec, patch):
    """Installiert eine App via Helm Chart."""
    helm_repo = spec.get("helmRepo")
    helm_values = spec.get("helmValues", {})
    port = spec.get("port", 8080)

    patch.status["phase"] = "Deploying"
    patch.status["message"] = f"Helm install '{helm_chart}'..."

    if helm_repo:
        repo_name = helm_chart.split("/")[0] if "/" in helm_chart else app_id.lower()
        result = _helm_cmd(["repo", "add", repo_name, helm_repo, "--force-update"])
        if result.returncode != 0:
            logger.warning("Helm repo add: %s", result.stderr)
        _helm_cmd(["repo", "update"])

    values_file = None
    if helm_values:
        values_file = tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", delete=False, prefix="jarvis-helm-"
        )
        yaml.dump(helm_values, values_file, default_flow_style=False)
        values_file.close()

    cmd = [
        "upgrade", "--install", name, helm_chart,
        "--namespace", namespace,
        "--wait", "--timeout", "5m",
    ]
    if values_file:
        cmd.extend(["--values", values_file.name])

    result = _helm_cmd(cmd)

    if values_file:
        os.unlink(values_file.name)

    if result.returncode != 0:
        error_msg = result.stderr.strip()[-200:]
        patch.status["phase"] = "Error"
        patch.status["message"] = f"Helm install fehlgeschlagen: {error_msg}"
        logger.error("Helm install '%s' failed: %s", app_id, result.stderr)
        return

    ingress_spec = spec.get("ingress", {})
    endpoint = f"{name}.{namespace}.svc.cluster.local:{port}"
    if ingress_spec.get("enabled", False):
        host = ingress_spec.get(
            "host", f"{app_id.lower()}.{namespace}.k8s.jarvis.local"
        )
        net_api = kubernetes.client.NetworkingV1Api()
        labels = {
            "app": name,
            "app.kubernetes.io/managed-by": "jarvis-operator",
            "app.kubernetes.io/part-of": "jarvis-os",
        }
        ingress = {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "Ingress",
            "metadata": {"name": f"{name}-jarvis", "namespace": namespace, "labels": labels},
            "spec": {
                "ingressClassName": "nginx",
                "rules": [
                    {
                        "host": host,
                        "http": {
                            "paths": [
                                {
                                    "path": "/",
                                    "pathType": "Prefix",
                                    "backend": {
                                        "service": {
                                            "name": name,
                                            "port": {"number": port},
                                        }
                                    },
                                }
                            ]
                        },
                    }
                ],
            },
        }
        try:
            net_api.create_namespaced_ingress(namespace, ingress)
        except kubernetes.client.exceptions.ApiException as e:
            if e.status != 409:
                raise
        endpoint = f"http://{host}"

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    patch.status["phase"] = "Running"
    patch.status["endpoint"] = endpoint
    patch.status["message"] = f"Helm release '{name}' deployed"
    patch.status["lastUpdated"] = now

    logger.info("Helm App '%s' deployed: %s", app_id, endpoint)


def _uninstall_helm(namespace, name, app_id):
    """Deinstalliert ein Helm-Release."""
    result = _helm_cmd(["uninstall", name, "--namespace", namespace])
    if result.returncode != 0:
        logger.warning("Helm uninstall '%s': %s", name, result.stderr)
    else:
        logger.info("Helm release '%s' deinstalliert", name)

    net_api = kubernetes.client.NetworkingV1Api()
    _safe_delete(lambda: net_api.delete_namespaced_ingress(f"{name}-jarvis", namespace))


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def _helm_cmd(args):
    """Fuehrt ein Helm-Kommando aus."""
    cmd = ["helm"] + args
    logger.debug("Helm: %s", " ".join(cmd))
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=600,
        env={
            "KUBECONFIG": "/etc/rancher/k3s/k3s.yaml",
            "HOME": "/root",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
        },
    )


def _apply_resource(create_fn, namespace, resource):
    """Create-or-skip: erstellt eine K8s-Resource, ignoriert 409 Conflict."""
    try:
        create_fn(namespace, resource)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status != 409:
            raise


def _safe_delete(delete_fn):
    """Loescht eine Resource, ignoriert 404 Not Found."""
    try:
        delete_fn()
    except kubernetes.client.exceptions.ApiException as e:
        if e.status != 404:
            raise

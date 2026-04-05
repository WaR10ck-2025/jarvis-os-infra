"""
J.A.R.V.I.S-OS Kubernetes Operator

Reconciles JarvisTenant and JarvisApp custom resources.
- JarvisTenant: Creates isolated namespace with quotas + network policies
- JarvisApp: Deploys containerized apps into tenant namespaces
"""

import datetime
import kopf
import kubernetes
import logging

logger = logging.getLogger("jarvis-operator")

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    settings.posting.level = logging.WARNING
    settings.persistence.finalizer = "jarvis-os.io/finalizer"
    # Reconcile every 5 minutes to catch drift
    settings.persistence.progress_storage = kopf.AnnotationsProgressStorage(
        prefix="jarvis-os.io"
    )
    logger.info("J.A.R.V.I.S-OS Operator gestartet")


# ---------------------------------------------------------------------------
# JarvisTenant — Create
# ---------------------------------------------------------------------------

@kopf.on.create("jarvis-os.io", "v1", "jarvistenants")
def tenant_create(spec, name, patch, **_):
    username = spec["username"]
    ns_name = f"user-{username}"

    logger.info(f"Erstelle Tenant '{username}' -> Namespace '{ns_name}'")

    api = kubernetes.client.CoreV1Api()

    # 1. Namespace erstellen
    ns = kubernetes.client.V1Namespace(
        metadata=kubernetes.client.V1ObjectMeta(
            name=ns_name,
            labels={
                "app.kubernetes.io/managed-by": "jarvis-operator",
                "jarvis-os.io/tenant": username,
                "app.kubernetes.io/part-of": "jarvis-os",
            },
        )
    )
    try:
        api.create_namespace(ns)
        logger.info(f"Namespace '{ns_name}' erstellt")
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 409:
            logger.info(f"Namespace '{ns_name}' existiert bereits")
        else:
            raise

    # 2. ResourceQuota
    storage_quota = spec.get("storageQuota", "50Gi")
    cpu_limit = spec.get("cpuLimit", "4")
    memory_limit = spec.get("memoryLimit", "8Gi")
    app_slot_limit = spec.get("appSlotLimit", 10)

    quota = kubernetes.client.V1ResourceQuota(
        metadata=kubernetes.client.V1ObjectMeta(
            name="tenant-quota",
            namespace=ns_name,
            labels={"jarvis-os.io/tenant": username},
        ),
        spec=kubernetes.client.V1ResourceQuotaSpec(
            hard={
                "requests.storage": storage_quota,
                "limits.cpu": cpu_limit,
                "limits.memory": memory_limit,
                "pods": str(app_slot_limit * 2),  # 2 Pods pro App (rolling update)
                "services": str(app_slot_limit),
                "persistentvolumeclaims": str(app_slot_limit),
            }
        ),
    )
    _apply_resource(api.create_namespaced_resource_quota, ns_name, quota)

    # 3. Default NetworkPolicy — isoliert den Namespace
    net_api = kubernetes.client.NetworkingV1Api()
    netpol = {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": "tenant-isolation",
            "namespace": ns_name,
            "labels": {"jarvis-os.io/tenant": username},
        },
        "spec": {
            "podSelector": {},  # Gilt fuer alle Pods im Namespace
            "policyTypes": ["Ingress", "Egress"],
            "ingress": [
                {
                    # Erlaube Traffic aus dem eigenen Namespace
                    "from": [{"namespaceSelector": {"matchLabels": {"jarvis-os.io/tenant": username}}}]
                },
                {
                    # Erlaube Ingress-Controller Traffic
                    "from": [{"namespaceSelector": {"matchLabels": {"app.kubernetes.io/name": "ingress-nginx"}}}]
                },
            ],
            "egress": [
                {
                    # DNS erlauben (kube-system)
                    "to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}}],
                    "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}],
                },
                {
                    # Egress ins Internet erlauben (aber nicht zu anderen Tenants)
                    "to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ["10.0.0.0/8"]}}],
                },
            ],
        },
    }
    custom_api = kubernetes.client.CustomObjectsApi()
    try:
        net_api.create_namespaced_network_policy(ns_name, netpol)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status != 409:
            raise

    # 4. Status updaten
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    patch.status["phase"] = "Ready"
    patch.status["namespace"] = ns_name
    patch.status["appCount"] = 0
    patch.status["message"] = "Tenant bereit"
    patch.status["lastUpdated"] = now

    logger.info(f"Tenant '{username}' ist Ready")
    return {"message": f"Namespace {ns_name} erstellt mit Quota und NetworkPolicy"}


# ---------------------------------------------------------------------------
# JarvisTenant — Delete
# ---------------------------------------------------------------------------

@kopf.on.delete("jarvis-os.io", "v1", "jarvistenants")
def tenant_delete(spec, name, **_):
    username = spec["username"]
    ns_name = f"user-{username}"

    logger.info(f"Loesche Tenant '{username}' -> Namespace '{ns_name}'")

    api = kubernetes.client.CoreV1Api()
    try:
        api.delete_namespace(ns_name)
        logger.info(f"Namespace '{ns_name}' geloescht")
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 404:
            logger.info(f"Namespace '{ns_name}' existiert nicht mehr")
        else:
            raise


# ---------------------------------------------------------------------------
# JarvisTenant — Update (Quota-Aenderungen)
# ---------------------------------------------------------------------------

@kopf.on.update("jarvis-os.io", "v1", "jarvistenants", field="spec")
def tenant_update(spec, name, patch, **_):
    username = spec["username"]
    ns_name = f"user-{username}"

    logger.info(f"Update Tenant '{username}' Quotas")

    api = kubernetes.client.CoreV1Api()
    storage_quota = spec.get("storageQuota", "50Gi")
    cpu_limit = spec.get("cpuLimit", "4")
    memory_limit = spec.get("memoryLimit", "8Gi")
    app_slot_limit = spec.get("appSlotLimit", 10)

    quota_patch = {
        "spec": {
            "hard": {
                "requests.storage": storage_quota,
                "limits.cpu": cpu_limit,
                "limits.memory": memory_limit,
                "pods": str(app_slot_limit * 2),
                "services": str(app_slot_limit),
                "persistentvolumeclaims": str(app_slot_limit),
            }
        }
    }
    try:
        api.patch_namespaced_resource_quota("tenant-quota", ns_name, quota_patch)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 404:
            logger.warning(f"Quota fuer '{ns_name}' nicht gefunden, erstelle neu")
            tenant_create(spec=spec, name=name, patch=patch)
            return
        raise

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    patch.status["message"] = "Quotas aktualisiert"
    patch.status["lastUpdated"] = now


# ---------------------------------------------------------------------------
# JarvisApp — Create
# ---------------------------------------------------------------------------

@kopf.on.create("jarvis-os.io", "v1", "jarvisapps")
def app_create(spec, name, namespace, patch, **_):
    app_id = spec["appId"]
    logger.info(f"Deploye App '{app_id}' in Namespace '{namespace}'")

    # Pruefen ob der Namespace ein Tenant-Namespace ist
    api = kubernetes.client.CoreV1Api()
    try:
        ns = api.read_namespace(namespace)
    except kubernetes.client.exceptions.ApiException:
        patch.status["phase"] = "Error"
        patch.status["message"] = f"Namespace '{namespace}' nicht gefunden"
        return

    tenant = ns.metadata.labels.get("jarvis-os.io/tenant") if ns.metadata.labels else None
    if not tenant:
        logger.warning(f"Namespace '{namespace}' ist kein Tenant-Namespace")

    image = spec.get("image")
    helm_chart = spec.get("helmChart")
    port = spec.get("port", 8080)

    if image:
        # Direktes Deployment (ohne Helm)
        _deploy_container(namespace, name, app_id, image, port, spec, patch)
    elif helm_chart:
        # Helm-basiertes Deployment (Platzhalter)
        patch.status["phase"] = "Pending"
        patch.status["message"] = f"Helm-Deployment fuer '{helm_chart}' noch nicht implementiert"
        logger.info(f"Helm-Deployment fuer '{app_id}' ist ein TODO")
    else:
        patch.status["phase"] = "Error"
        patch.status["message"] = "Entweder 'image' oder 'helmChart' muss angegeben werden"
        return

    _update_tenant_app_count(namespace)


# ---------------------------------------------------------------------------
# JarvisApp — Delete
# ---------------------------------------------------------------------------

@kopf.on.delete("jarvis-os.io", "v1", "jarvisapps")
def app_delete(spec, name, namespace, **_):
    app_id = spec["appId"]
    logger.info(f"Loesche App '{app_id}' aus Namespace '{namespace}'")

    apps_api = kubernetes.client.AppsV1Api()
    api = kubernetes.client.CoreV1Api()
    net_api = kubernetes.client.NetworkingV1Api()

    # Deployment loeschen
    _safe_delete(lambda: apps_api.delete_namespaced_deployment(name, namespace))
    # Service loeschen
    _safe_delete(lambda: api.delete_namespaced_service(name, namespace))
    # Ingress loeschen
    _safe_delete(lambda: net_api.delete_namespaced_ingress(name, namespace))
    # PVC loeschen (wenn vorhanden)
    _safe_delete(lambda: api.delete_namespaced_persistent_volume_claim(f"{name}-data", namespace))

    _update_tenant_app_count(namespace)
    logger.info(f"App '{app_id}' aus '{namespace}' entfernt")


# ---------------------------------------------------------------------------
# Helpers
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

        # PVC erstellen
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

    logger.info(f"App '{app_id}' laeuft unter {endpoint}")


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


def _update_tenant_app_count(namespace):
    """Zaehlt JarvisApps im Namespace und aktualisiert den Tenant-Status."""
    custom_api = kubernetes.client.CustomObjectsApi()
    try:
        apps = custom_api.list_namespaced_custom_object(
            "jarvis-os.io", "v1", namespace, "jarvisapps"
        )
        count = len(apps.get("items", []))
    except kubernetes.client.exceptions.ApiException:
        return

    # Tenant finden (Cluster-scoped, suche nach Namespace-Label)
    try:
        tenants = custom_api.list_cluster_custom_object(
            "jarvis-os.io", "v1", "jarvistenants"
        )
        for tenant in tenants.get("items", []):
            if tenant.get("status", {}).get("namespace") == namespace:
                custom_api.patch_cluster_custom_object_status(
                    "jarvis-os.io",
                    "v1",
                    "jarvistenants",
                    tenant["metadata"]["name"],
                    {"status": {"appCount": count}},
                )
                break
    except kubernetes.client.exceptions.ApiException:
        pass

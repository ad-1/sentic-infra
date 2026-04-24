# sentic-infra

> Infrastructure for the Sentic platform — owns the shared RabbitMQ broker used by sentic-signal, sentic-analyst, and sentic-notifier.

## Architecture

RabbitMQ is managed by two official Kubernetes operators:

| Operator | Purpose | CRD |
|---|---|---|
| [Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/using-operator) | Provisions and manages the RabbitMQ StatefulSet, Services, Secrets, and config | `RabbitmqCluster` |
| [Messaging Topology Operator](https://www.rabbitmq.com/kubernetes/operator/using-topology-operator) | Declares and continuously reconciles queues, exchanges, bindings, users, and vhosts | `Queue`, `Exchange`, `Binding`, … |

This means **all broker config lives as version-controlled YAML** — no `rabbitmqadmin` scripts, no post-install jobs.

---

## Repo structure

```
sentic-infra/
├── definition.yaml        # RabbitmqCluster — broker spec (resources, persistence, plugins)
├── topology/
│   └── queues.yaml        # Queue CRDs — one per Sentic queue
├── Makefile               # Workflow commands
└── README.md
```

---

## Prerequisites

You need these operators installed once per cluster. The Makefile wraps all three steps.

### Automated (minikube / fresh cluster)

```bash
make bootstrap
```

This runs, in order:

1. **cert-manager** — required by the Topology Operator for its webhook TLS.
2. **RabbitMQ Cluster Operator** — manages `RabbitmqCluster` resources.
3. **RabbitMQ Messaging Topology Operator** — manages `Queue` and other topology resources.

### Manual (if you prefer explicit control)

```bash
# 1. cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl rollout status -n cert-manager deploy/cert-manager --timeout=120s

# 2. Cluster Operator
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# 3. Topology Operator (cert-manager variant)
kubectl apply -f https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator-with-certmanager.yaml
```

---

## Namespace Architecture

The operators run in **system namespaces** and watch your **application namespace**:

```
System namespaces (installed once, cluster-scoped):
  cert-manager         → runs cert-manager (webhook TLS)
  rabbitmq-system      → runs Cluster Operator + Topology Operator

These watch all namespaces. For Sentic:
  sentic               → RabbitMQ broker pods, services, queues
```

- **`cert-manager`** — Webhook certificate management for the operators. Installed cluster-wide once.
- **`rabbitmq-system`** — Both RabbitMQ operators run here. They're cluster-scoped and reconcile `RabbitmqCluster` and `Queue` CRDs in any namespace.
- **`sentic`** — Your RabbitMQ broker pods, services, and queue topology CRDs. Application workloads also run here.

This is why `make bootstrap` installs everything, but `make apply` deploys into `sentic` only.

---

## Deploying RabbitMQ

```bash
# Deploy the broker cluster + all queues in one step
make apply

# Wait until the broker pod is Ready
make wait
```

Under the hood this runs:
```bash
kubectl apply -f definition.yaml      # RabbitmqCluster
kubectl apply -f topology/queues.yaml # Queue resources
```

### Verify

```bash
make status

# Expected output:
# NAME         ALLREPLICASREADY   RECONCILESUCCESS   AGE
# definition   True               True               2m
#
# NAME               READY
# raw-news           True
# analysis-results   True
# notifications      True
```

---

## Queues

Declared in [topology/queues.yaml](topology/queues.yaml). The Topology Operator reconciles these continuously — if a queue is deleted in the broker it will be re-declared automatically.

| Queue | Producer | Consumer |
|---|---|---|
| `raw-news` | sentic-signal | sentic-analyst |
| `analysis-results` | sentic-analyst | sentic-notifier |
| `notifications` | sentic-notifier | — |

### Adding a new queue

1. Append a new `Queue` block to `topology/queues.yaml`.
2. `kubectl apply -f topology/queues.yaml` (or `make apply-topology`).

---

## Credentials

The Cluster Operator auto-generates admin credentials and stores them in a Secret named `<cluster>-default-user`.

```bash
make username   # print admin username
make password   # print admin password
make amqp-url   # print full AMQP URL
# → amqp://9JkXq...:Wv3R...@definition.sentic.svc.cluster.local:5672/
```

### How services consume credentials

Services should reference the operator-managed Secret directly — **never hard-code credentials**.

```yaml
# In a service Deployment
env:
  - name: RABBITMQ_USERNAME
    valueFrom:
      secretKeyRef:
        name: definition-default-user   # <clusterName>-default-user
        key: username
  - name: RABBITMQ_PASSWORD
    valueFrom:
      secretKeyRef:
        name: definition-default-user
        key: password
  - name: RABBITMQ_HOST
    value: definition.sentic.svc.cluster.local
  - name: RABBITMQ_PORT
    value: "5672"
```

The Secret is in the `sentic` namespace — services running in the same namespace can reference it directly.

---

## Management UI (local dev)

```bash
make port-forward
# → AMQP on localhost:5672
# → Management UI at http://localhost:15672
```

Login with the credentials from `make username` / `make password`.

---

## Makefile reference

| Target | Description |
|---|---|
| `bootstrap` | Install cert-manager + both operators (run once per cluster) |
| `install-cert-manager` | Install cert-manager only |
| `install-cluster-operator` | Install RabbitMQ Cluster Operator only |
| `install-topology-operator` | Install Messaging Topology Operator only |
| `apply` | Deploy cluster + topology |
| `apply-cluster` | Deploy/update `definition.yaml` only |
| `apply-topology` | Deploy/update `topology/queues.yaml` only |
| `wait` | Block until broker pod is Ready |
| `status` | Show cluster and queue status |
| `logs` | Tail broker logs |
| `username` | Print admin username |
| `password` | Print admin password |
| `amqp-url` | Print full AMQP connection URL |
| `port-forward` | Forward ports 5672 and 15672 to localhost |
| `delete-cluster` | Delete the RabbitmqCluster (PVCs kept) |
| `delete-topology` | Delete Queue resources |

Override defaults:

```bash
make apply KUBE_CTX=my-cluster NAMESPACE=platform
```

---

## Key differences from the previous Helm chart approach

| Concern | Old (Helm/Bitnami) | New (Operator) |
|---|---|---|
| Broker deployment | Helm subchart, ~50 lines of values | 40-line `RabbitmqCluster` YAML |
| Queue declarations | Post-install Job hitting HTTP API | `Queue` CRDs, continuously reconciled |
| Credentials | Custom post-install Job writing a Secret | Auto-generated `<name>-default-user` Secret |
| Updates | `helm upgrade` | `kubectl apply` |
| Queue drift | Not detected | Operator re-declares deleted queues automatically |

---

## Troubleshooting

### Operators not starting (API timeout)

Symptoms:
```
error: "unable to start manager", error: "failed to get server groups: Get \"https://10.96.0.1:443/api\": dial tcp i/o timeout"
```

The operator pod can't reach the Kubernetes API server.

**Solutions:**
1. Verify minikube is running: `minikube status`
2. Give operators time to initialize (30–60s): `kubectl -n rabbitmq-system logs -f deploy/rabbitmq-cluster-operator`
3. If persistent, restart minikube:
   ```bash
   minikube stop
   minikube start
   make bootstrap
   ```

### RabbitmqCluster pod not scheduling

Pod `definition-server-0` stays in `Pending` state.

**Check:**
```bash
kubectl -n sentic describe pod definition-server-0
```

Common causes:
- **No default StorageClass** — minikube provides `standard`. Verify: `kubectl get storageclass`
- **Insufficient resources** — reduce `spec.resources.limits` in `definition.yaml`
- **PVC pending** — check: `kubectl -n sentic get pvc`

### Queue topology resources not creating

`Queue` CRDs stay non-Ready or show errors.

**Check:**
```bash
kubectl -n sentic get queue
kubectl -n sentic describe queue raw-news
```

Common causes:
- **Topology Operator not installed** — run `make bootstrap`
- **RabbitmqCluster not ready** — queues can't be declared until the broker pod is `Running`
- **API errors** — check operator logs: `kubectl -n rabbitmq-system logs -f deploy/messaging-topology-operator`

### Can't reach management UI

```bash
make port-forward
# Then: http://localhost:15672
```

If port-forward fails:
- Service exists: `kubectl -n sentic get svc definition`
- Pod is running: `kubectl -n sentic get pod definition-server-0`
- Check logs: `make logs`

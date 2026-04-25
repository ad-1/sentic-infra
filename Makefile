NAMESPACE  := sentic
CLUSTER    := definition
KUBE_CTX   ?= minikube
TARGET     ?= rabbitmq

KUBECTL    := kubectl --context=$(KUBE_CTX) -n $(NAMESPACE)

# Variables
export GITHUB_PAT ?= $(shell test -f ~/.github_pat && cat ~/.github_pat) # Or use an Env Var
REPO_URL = https://github.com/ad-1/sentic-infra.git

# ---------------------------------------------------------------------------
# Bootstrap ArgoCD and install operators via GitOps
# ---------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap:
	@test -n "$(GITHUB_PAT)" || (echo "❌ ERROR: GITHUB_PAT is not set. Export it or create ~/.github_pat"; exit 1)

	@echo "🏗️  Installing ArgoCD..."
	@kubectl create namespace argocd || true
	@# Pre-create all required namespaces so ArgoCD never races against a missing ns
	@kubectl create namespace cert-manager || true
	@kubectl create namespace rabbitmq-system || true
	@kubectl create namespace sentic || true
	@# Use server-side apply for idempotence. --force-conflicts is required when
	@# an existing cluster has ArgoCD resources previously created with client-side apply.
	@kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

	@echo "⏳ Waiting for ArgoCD CRDs to be established..."
	@kubectl wait --for=condition=established --timeout=60s crd/applications.argoproj.io

	@echo "⏳ Waiting for ArgoCD Server to be ready..."
	@kubectl wait --for=condition=available --timeout=300s -n argocd deployment/argocd-server

	@echo "🔐 Injecting Repo Credentials (atomic — no disk write, no separate label step)..."
	@# Triple-pipe: generate YAML → label in-memory → apply. The secret and its
	@# argocd.argoproj.io/secret-type label land in one atomic kubectl apply.
	@kubectl create secret generic repo-creds \
		-n argocd \
		--from-literal=url=$(REPO_URL) \
		--from-literal=password=$(GITHUB_PAT) \
		--from-literal=username=ad-1 \
		--type=Opaque \
		--dry-run=client -o yaml \
	  | kubectl label --local -f - \
		argocd.argoproj.io/secret-type=repository \
		--overwrite -o yaml \
	  | kubectl apply -f -

	@echo "🚀 Applying Root Application..."
	@kubectl apply -f argocd/application.yaml

# ---------------------------------------------------------------------------
# Prerequisites — run once per cluster
# Install the operators that manage RabbitmqCluster and Queue CRDs.
# These install into `cert-manager` and `rabbitmq-system` namespaces
# (cluster-scoped), and then watch all namespaces including `sentic`.
# See README.md "Namespace Architecture" for details.
# ---------------------------------------------------------------------------

## Install cert-manager (required by the Messaging Topology Operator)
.PHONY: install-cert-manager
install-cert-manager:
	kubectl apply --context=$(KUBE_CTX) \
		-f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
	kubectl rollout status -n cert-manager deploy/cert-manager --timeout=120s

## Install the RabbitMQ Cluster Operator
.PHONY: install-cluster-operator
install-cluster-operator:
	kubectl apply --context=$(KUBE_CTX) \
		-f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml
	kubectl rollout status -n rabbitmq-system deploy/rabbitmq-cluster-operator --timeout=120s

## Install the RabbitMQ Messaging Topology Operator (requires cert-manager)
.PHONY: install-topology-operator
install-topology-operator:
	kubectl apply --context=$(KUBE_CTX) \
		-f https://github.com/rabbitmq/messaging-topology-operator/releases/latest/download/messaging-topology-operator-with-certmanager.yaml
	kubectl rollout status -n rabbitmq-system deploy/messaging-topology-operator --timeout=120s

## Bootstrap a brand-new cluster: install all operators in the right order
.PHONY: bootstrap-legacy
bootstrap-legacy: install-cert-manager install-cluster-operator install-topology-operator

# ---------------------------------------------------------------------------
# Sentic RabbitMQ deployment
# ---------------------------------------------------------------------------

## Create the sentic namespace (idempotent)
.PHONY: ns
ns:
	kubectl create namespace $(NAMESPACE) --context=$(KUBE_CTX) --dry-run=client -o yaml | \
		kubectl apply --context=$(KUBE_CTX) -f -

## Deploy the RabbitmqCluster
.PHONY: apply-cluster
apply-cluster: ns
	$(KUBECTL) apply -f manifests/cluster/definition.yaml

## Deploy queue topology (requires Messaging Topology Operator)
.PHONY: apply-topology
apply-topology:
	$(KUBECTL) apply -f manifests/topology/queues.yaml

## Deploy everything
.PHONY: apply
apply: apply-cluster apply-topology

## Wait for the broker pod to be ready
.PHONY: wait
wait:
	$(KUBECTL) wait pod \
		-l app.kubernetes.io/name=$(CLUSTER) \
		--for=condition=Ready \
		--timeout=180s

# ---------------------------------------------------------------------------
# Credentials helpers
# ---------------------------------------------------------------------------

## Print the auto-generated admin username
.PHONY: username
username:
	@$(KUBECTL) get secret $(CLUSTER)-default-user \
		-o jsonpath="{.data.username}" | base64 --decode; echo

## Print the auto-generated admin password
.PHONY: password
password:
	@$(KUBECTL) get secret $(CLUSTER)-default-user \
		-o jsonpath="{.data.password}" | base64 --decode; echo

## Print the full AMQP URL (safe for use in shell scripts)
.PHONY: amqp-url
amqp-url:
	@U=$$($(KUBECTL) get secret $(CLUSTER)-default-user -o jsonpath="{.data.username}" | base64 --decode); \
	 P=$$($(KUBECTL) get secret $(CLUSTER)-default-user -o jsonpath="{.data.password}" | base64 --decode); \
	 echo "amqp://$$U:$$P@$(CLUSTER).$(NAMESPACE).svc.cluster.local:5672/"

# ---------------------------------------------------------------------------
# Development helpers
# ---------------------------------------------------------------------------

## Show cluster status
.PHONY: status
status:
	$(KUBECTL) get rabbitmqcluster $(CLUSTER)
	$(KUBECTL) get queue -l app.kubernetes.io/name=$(CLUSTER)

## Tail broker logs
.PHONY: logs
logs:
	$(KUBECTL) logs -l app.kubernetes.io/name=$(CLUSTER) -f --tail=50

## Delete the RabbitmqCluster (leaves PVCs intact)
.PHONY: delete-cluster
delete-cluster:
	$(KUBECTL) delete -f manifests/cluster/definition.yaml

## Delete queue topology resources
.PHONY: delete-topology
delete-topology:
	$(KUBECTL) delete -f manifests/topology/queues.yaml

## Port-Forward: Generic port-forward helper.
## Usage:
##   make port-forward # RabbitMQ + ArgoCD
.PHONY: port-forward
port-forward:
	echo "🔌 Opening both tunnels (RabbitMQ + ArgoCD). Ctrl+C stops both..."; \
	kubectl --context=$(KUBE_CTX) -n argocd port-forward svc/argocd-server 8080:443 & \
	ARGO_PID=$$!; \
	$(KUBECTL) port-forward svc/$(CLUSTER) 5672:5672 15672:15672 & \
	RABBIT_PID=$$!; \
	trap 'kill $$ARGO_PID $$RABBIT_PID 2>/dev/null' INT TERM EXIT; \
	wait; 

## Repave: The Orchestrator
.PHONY: repave
repave:
	@echo "🧹 Step 1/5 — Tearing down (ignoring errors if not found)..."
	@$(KUBECTL) delete -f manifests/topology/queues.yaml --ignore-not-found
	@$(KUBECTL) delete -f manifests/cluster/definition.yaml --ignore-not-found
	
	@echo "🐇 Step 2/5 — Applying definitions..."
	@$(MAKE) -s apply
	
	@echo "⏳ Step 3/5 — Waiting 10s for Operator to reconcile..."
	@sleep 10
	
	@echo "🟢 Step 4/5 — Blocking until pod is Ready..."
	@$(MAKE) -s wait
	
	@echo "🔐 Step 5/5 — Extraction complete. Credentials:"
	@echo "---------------------------------------------------"
	@printf "Username: "; $(MAKE) -s username
	@printf "Password: "; $(MAKE) -s password
	@printf "AMQP URL: "; $(MAKE) -s amqp-url
	@echo "---------------------------------------------------"
	@echo "🚀 SUCCESS: Infrastructure is live."
	@echo "👉 Run 'make port-forward' for RabbitMQ or 'make port-forward TARGET=argocd' for ArgoCD UI"

## Force-Repave: Wipes EVERYTHING including persistent data (PVCs)
.PHONY: repave-hard
repave-hard: delete-topology
	$(KUBECTL) delete rabbitmqcluster --all
	$(KUBECTL) delete pvc --all
	$(MAKE) apply
	@echo "🔥 Hard repave complete. All data wiped and infra reset."
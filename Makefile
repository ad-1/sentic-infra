NAMESPACE  := sentic
CLUSTER    := definition
KUBE_CTX   ?= minikube
TARGET     ?= rabbitmq
ROOT_APP   := argocd/application.yaml
SMOKE_QUEUE ?= raw-news

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
	@kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	@# Pre-create all required namespaces so ArgoCD never races against a missing ns
	@kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace rabbitmq-system --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace sentic --dry-run=client -o yaml | kubectl apply -f -
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
	@kubectl apply -f $(ROOT_APP)

## Wait for ArgoCD to reconcile operator Applications after bootstrap/nuke
.PHONY: wait-argocd-operator-apps
wait-argocd-operator-apps:
	@echo "⏳ Waiting for ArgoCD operator applications to be Synced + Healthy..."
	@for app in cert-manager rabbitmq-cluster-operator rabbitmq-messaging-topology-operator; do \
		if [ "$$app" = "cert-manager" ]; then NS=cert-manager; else NS=rabbitmq-system; fi; \
		echo "   • Ensuring app $$app exists..."; \
		for i in $$(seq 1 90); do \
			if kubectl --context=$(KUBE_CTX) -n argocd get app $$app >/dev/null 2>&1; then \
				break; \
			fi; \
			if [ $$(expr $$i % 10) -eq 0 ]; then \
				echo "     still waiting for app $$app to be created... ($$((i*2))s elapsed)"; \
			fi; \
			sleep 2; \
		done; \
		if ! kubectl --context=$(KUBE_CTX) -n argocd get app $$app >/dev/null 2>&1; then \
			echo "❌ ArgoCD app $$app was not created within 180s."; \
			echo "   Root app status (if available):"; \
			kubectl --context=$(KUBE_CTX) -n argocd get app sentic-infra -o wide || true; \
			exit 1; \
		fi; \
		echo "   • Waiting for app $$app to be Synced + Healthy..."; \
		for i in $$(seq 1 180); do \
			SYNC=$$(kubectl --context=$(KUBE_CTX) -n argocd get app $$app -o jsonpath='{.status.sync.status}' 2>/dev/null); \
			HEALTH=$$(kubectl --context=$(KUBE_CTX) -n argocd get app $$app -o jsonpath='{.status.health.status}' 2>/dev/null); \
			BLOCKERS=$$(kubectl --context=$(KUBE_CTX) -n $$NS get pods --no-headers 2>/dev/null | \
				awk '$$3 ~ /ImagePullBackOff|ErrImagePull|CrashLoopBackOff|CreateContainerConfigError|InvalidImageName/ {print $$1" status="$$3}'); \
			if [ -n "$$BLOCKERS" ]; then \
				echo "❌ Detected rollout blockers in namespace $$NS while waiting for $$app:"; \
				echo "$$BLOCKERS"; \
				echo "   Recent events from $$NS:"; \
				kubectl --context=$(KUBE_CTX) -n $$NS get events --sort-by=.lastTimestamp | tail -n 20; \
				exit 1; \
			fi; \
			if [ "$$HEALTH" = "Degraded" ]; then \
				echo "❌ ArgoCD app $$app became Degraded (sync=$$SYNC)."; \
				kubectl --context=$(KUBE_CTX) -n argocd get app $$app -o wide; \
				echo "   Recent events from $$NS:"; \
				kubectl --context=$(KUBE_CTX) -n $$NS get events --sort-by=.lastTimestamp | tail -n 20; \
				exit 1; \
			fi; \
			if [ "$$SYNC" = "Synced" ] && [ "$$HEALTH" = "Healthy" ]; then \
				echo "✅ $$app is Synced + Healthy."; \
				break; \
			fi; \
			if [ $$(expr $$i % 10) -eq 0 ]; then \
				echo "     $$app sync=$$SYNC health=$$HEALTH ($$((i*2))s elapsed)"; \
			fi; \
			sleep 2; \
		done; \
		SYNC=$$(kubectl --context=$(KUBE_CTX) -n argocd get app $$app -o jsonpath='{.status.sync.status}' 2>/dev/null); \
		HEALTH=$$(kubectl --context=$(KUBE_CTX) -n argocd get app $$app -o jsonpath='{.status.health.status}' 2>/dev/null); \
		if [ "$$SYNC" != "Synced" ] || [ "$$HEALTH" != "Healthy" ]; then \
			echo "❌ ArgoCD app $$app is not ready (sync=$$SYNC, health=$$HEALTH)."; \
			echo "   App status:"; \
			kubectl --context=$(KUBE_CTX) -n argocd get app $$app -o wide; \
			echo "   Recent events from $$NS:"; \
			kubectl --context=$(KUBE_CTX) -n $$NS get events --sort-by=.lastTimestamp | tail -n 20; \
			exit 1; \
		fi; \
	done

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
.PHONY: wait-cluster-operator
wait-cluster-operator:
	@echo "⏳ Verifying RabbitMQ Cluster Operator is ready..."
	@kubectl --context=$(KUBE_CTX) -n rabbitmq-system get deployment/rabbitmq-cluster-operator >/dev/null 2>&1 || { \
		echo "❌ rabbitmq-cluster-operator deployment not found in namespace rabbitmq-system."; \
		echo "   Fix: run 'make bootstrap' (GitOps path) or 'make install-cluster-operator' (legacy path), then retry."; \
		exit 1; \
	}
	@kubectl --context=$(KUBE_CTX) -n rabbitmq-system rollout status deployment/rabbitmq-cluster-operator --timeout=180s

.PHONY: apply-cluster
apply-cluster: ns wait-cluster-operator
	$(KUBECTL) apply -f manifests/cluster/definition.yaml

## Deploy queue topology (requires Messaging Topology Operator)
.PHONY: wait-topology-operator
wait-topology-operator:
	@echo "⏳ Verifying Messaging Topology Operator is ready..."
	@kubectl --context=$(KUBE_CTX) -n rabbitmq-system get deployment/messaging-topology-operator >/dev/null 2>&1 || { \
		echo "❌ messaging-topology-operator deployment not found in namespace rabbitmq-system."; \
		echo "   Detected state is consistent with a stale validating webhook and no running operator."; \
		echo "   Fix: run 'make bootstrap' (GitOps path) or 'make install-topology-operator' (legacy path), then retry."; \
		exit 1; \
	}
	@kubectl --context=$(KUBE_CTX) -n rabbitmq-system rollout status deployment/messaging-topology-operator --timeout=240s || { \
		echo "❌ messaging-topology-operator failed to become Available before timeout."; \
		echo "   Recent rabbitmq-system pods:"; \
		kubectl --context=$(KUBE_CTX) -n rabbitmq-system get pods -o wide; \
		echo "   Recent rabbitmq-system events:"; \
		kubectl --context=$(KUBE_CTX) -n rabbitmq-system get events --sort-by=.lastTimestamp | tail -n 20; \
		exit 1; \
	}
	@for i in $$(seq 1 30); do \
		if kubectl --context=$(KUBE_CTX) -n rabbitmq-system get svc messaging-topology-webhook-service >/dev/null 2>&1; then \
			echo "✅ messaging-topology-webhook-service is available."; \
			exit 0; \
		fi; \
		sleep 2; \
	done; \
	echo "❌ messaging-topology-webhook-service did not appear in namespace rabbitmq-system within 60s."; \
	echo "   Check operator health with: kubectl --context=$(KUBE_CTX) -n rabbitmq-system get pods"; \
	exit 1

.PHONY: apply-topology
apply-topology: wait-topology-operator
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

## Provision all external service secrets (idempotent).
## Reads from environment variables — export them before running:
##   export ALPHA_VANTAGE_KEY=...  FINNHUB_API_KEY=...  TELEGRAM_BOT_TOKEN=...  TELEGRAM_CHAT_ID=...
## See docs/adr/ADR-004-SECRET-MANAGEMENT.md for full strategy and rotation instructions.
.PHONY: secrets
secrets:
	@test -n "$(KUBE_CTX)" || (echo "❌ KUBE_CTX is not set."; exit 1)
	@sh scripts/provision-secrets.sh --context $(KUBE_CTX) --namespace $(NAMESPACE)

## Print the auto-generated admin username
.PHONY: username
username:
	@$(KUBECTL) get secret $(CLUSTER)-default-user \
		-o jsonpath="{.data.username}" | base64 --decode; echo

## Print RabbitMQ + ArgoCD admin passwords
.PHONY: password
password:
	@echo "RabbitMQ password: $$( $(KUBECTL) get secret $(CLUSTER)-default-user -o jsonpath='{.data.password}' | base64 --decode )"
	@echo "ArgoCD password:   $$( kubectl --context=$(KUBE_CTX) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode )"

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
	$(KUBECTL) get queue

## Preflight: verify configured operator image tags exist in registries
.PHONY: validate-operator-tags
validate-operator-tags:
	@echo "🔎 Validating configured operator image tags in registries..."
	@CLUSTER_TAG=$$(awk -F: '/cluster-operator-dev=/{gsub(/[[:space:]]/, "", $$0); print $$NF; exit}' manifests/operators/rabbitmq-cluster-operator.yaml); \
	 TOPO_TAG=$$(awk -F: '/localhost\/messaging-topology-operator=/{gsub(/[[:space:]]/, "", $$0); print $$NF; exit}' manifests/operators/rabbitmq-messaging-topology-operator.yaml); \
	 test -n "$$CLUSTER_TAG" || { echo "❌ Could not parse cluster operator tag from manifests/operators/rabbitmq-cluster-operator.yaml"; exit 1; }; \
	 test -n "$$TOPO_TAG" || { echo "❌ Could not parse topology operator tag from manifests/operators/rabbitmq-messaging-topology-operator.yaml"; exit 1; }; \
	 echo "   Cluster operator tag: $$CLUSTER_TAG"; \
	 echo "   Topology operator tag: $$TOPO_TAG"; \
	 GHCR_TOKEN=$$(curl -fsSL 'https://ghcr.io/token?service=ghcr.io&scope=repository:rabbitmq/cluster-operator:pull' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'); \
	 test -n "$$GHCR_TOKEN" || { echo "❌ Failed to retrieve GHCR token for rabbitmq/cluster-operator."; exit 1; }; \
	 GHCR_CODE=$$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $$GHCR_TOKEN" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "https://ghcr.io/v2/rabbitmq/cluster-operator/manifests/$$CLUSTER_TAG"); \
	 if [ "$$GHCR_CODE" != "200" ]; then \
		echo "❌ Cluster operator tag '$$CLUSTER_TAG' not found in ghcr.io/rabbitmq/cluster-operator (HTTP $$GHCR_CODE)."; \
		exit 1; \
	 fi; \
	 DOCKER_TOKEN=$$(curl -fsSL 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:rabbitmqoperator/messaging-topology-operator:pull' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'); \
	 test -n "$$DOCKER_TOKEN" || { echo "❌ Failed to retrieve Docker Hub token for rabbitmqoperator/messaging-topology-operator."; exit 1; }; \
	 DOCKER_CODE=$$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $$DOCKER_TOKEN" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "https://registry-1.docker.io/v2/rabbitmqoperator/messaging-topology-operator/manifests/$$TOPO_TAG"); \
	 if [ "$$DOCKER_CODE" != "200" ]; then \
		echo "❌ Topology operator tag '$$TOPO_TAG' not found in rabbitmqoperator/messaging-topology-operator (HTTP $$DOCKER_CODE)."; \
		exit 1; \
	 fi; \
	 echo "✅ Operator image tags are available in registries."

## Verify operators are not configured with localhost-only image references
.PHONY: check-operator-images
check-operator-images:
	@echo "🔎 Checking operator deployment image references..."
	@BAD=$$(kubectl --context=$(KUBE_CTX) -n rabbitmq-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>/dev/null | \
		awk -F= '$$1 ~ /rabbitmq-cluster-operator|messaging-topology-operator/ && ($$2 ~ /(^|[[:space:]])localhost\// || $$2 ~ /ghcr\.io\/rabbitmq\/cluster-operator:v[0-9]/ || $$2 ~ /rabbitmqoperator\/messaging-topology-operator:v[0-9]/) {print $$0}'); \
	if [ -n "$$BAD" ]; then \
		echo "❌ Found invalid operator image references:"; \
		echo "$$BAD"; \
		echo "   Use non-localhost images and release tags without a v-prefix (e.g., 2.20.1, 1.19.1)."; \
		echo "   Reconcile Argo apps and image tags before retrying."; \
		exit 1; \
	fi; \
	echo "✅ Operator images look cluster-reachable."

## Fail fast if pods are stuck in image pull / startup backoff states
.PHONY: check-pod-health
check-pod-health:
	@echo "🔎 Checking for pod health issues (image pull/backoff states)..."
	@FAILED=$$(kubectl --context=$(KUBE_CTX) get pods -A --no-headers 2>/dev/null | \
		awk '$$4 ~ /ImagePullBackOff|ErrImagePull|CrashLoopBackOff|CreateContainerConfigError/ {print $$1"/"$$2" status="$$4}'); \
	if [ -n "$$FAILED" ]; then \
		echo "❌ Found unhealthy pods:"; \
		echo "$$FAILED"; \
		echo "   Use: kubectl --context=$(KUBE_CTX) -n <namespace> describe pod <pod-name>"; \
		exit 1; \
	fi; \
	echo "✅ No image-pull/backoff pod states detected."

## Validate all required control-plane and workload resources
.PHONY: validate
validate: wait-cluster-operator wait-topology-operator wait status check-operator-images check-pod-health
	@echo "✅ Validation checks passed."

## Smoke-test publish + consume path via RabbitMQ management API
.PHONY: smoke-test
smoke-test:
	@sh scripts/rabbitmq_smoke_test.sh "$(KUBE_CTX)" "$(NAMESPACE)" "$(CLUSTER)" "$(SMOKE_QUEUE)"

## One-shot setup and verification flow for a fresh cluster
.PHONY: setup-validate
setup-validate: validate-operator-tags bootstrap wait-argocd-operator-apps apply validate smoke-test
	@echo "🚀 Setup + validation completed successfully."

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

## Repave: Full destructive rebuild (nuke + bootstrap + apply + validate + smoke test)
.PHONY: repave
repave:
	@echo "🔎 Step 1/8 — Validating operator image tags before rebuild..."
	@$(MAKE) -s validate-operator-tags
	@echo "💥 Step 2/8 — Nuking resources and re-bootstrapping ArgoCD..."
	@$(MAKE) -s nuke
	@echo "⏳ Step 3/8 — Waiting for ArgoCD operator apps to reconcile..."
	@$(MAKE) -s wait-argocd-operator-apps
	@echo "🐇 Step 4/8 — Applying RabbitMQ cluster + topology manifests..."
	@$(MAKE) -s apply
	@echo "🟢 Step 5/8 — Running readiness and health validation checks..."
	@$(MAKE) -s validate
	@echo "🧪 Step 6/8 — Running publish/consume smoke test..."
	@$(MAKE) -s smoke-test
	@echo "🔐 Step 7/8 — Extracting credentials..."
	@echo "---------------------------------------------------"
	@printf "Username: "; $(MAKE) -s username
	@$(MAKE) -s password
	@printf "AMQP URL: "; $(MAKE) -s amqp-url
	@echo "---------------------------------------------------"
	@echo "🚀 Step 8/8 — SUCCESS: Clean rebuild + validation complete."
	@echo "👉 Run 'make port-forward' to open RabbitMQ + ArgoCD tunnels."

## Force-Repave: Legacy alias for repave
.PHONY: repave-hard
repave-hard:
	@echo "⚠️  repave-hard is now an alias of repave."
	@$(MAKE) -s repave

.PHONY: refresh nuke

## Refresh: Force ArgoCD to re-sync from Git immediately
refresh:
	kubectl --context=$(KUBE_CTX) -n argocd patch app sentic-infra \
		-p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' \
		--type=merge

## Nuke: Wipe all ArgoCD-managed resources and re-bootstrap from scratch.
## Use this when the cluster state is too tangled to recover gracefully.
## Deletes all ArgoCD Applications and managed RabbitMQ/operator resources,
## then runs bootstrap to rebuild from Git as the source of truth.
.PHONY: wait-operator-namespaces-gone
wait-operator-namespaces-gone:
	@for ns in cert-manager rabbitmq-system; do \
		echo "⏳ Waiting for namespace $$ns to terminate (if present)..."; \
		for i in $$(seq 1 60); do \
			if ! kubectl --context=$(KUBE_CTX) get namespace $$ns >/dev/null 2>&1; then \
				echo "✅ Namespace $$ns is gone."; \
				break; \
			fi; \
			sleep 2; \
		done; \
		if kubectl --context=$(KUBE_CTX) get namespace $$ns >/dev/null 2>&1; then \
			echo "❌ Namespace $$ns still exists after 120s."; \
			kubectl --context=$(KUBE_CTX) get namespace $$ns -o yaml | sed -n '1,40p'; \
			exit 1; \
		fi; \
	done

.PHONY: nuke
nuke:
	@echo "💥 Step 1/6 — Deleting ALL ArgoCD Applications (cascade=foreground)..."
	@kubectl --context=$(KUBE_CTX) -n argocd delete app --all \
		--cascade=foreground --ignore-not-found --timeout=300s || true
	@echo "🧹 Step 2/6 — Cleaning up leftover RabbitMQ resources in sentic..."
	@$(KUBECTL) delete rabbitmqcluster --all --ignore-not-found || true
	@$(KUBECTL) delete queues.rabbitmq.com --all --ignore-not-found || true
	@$(KUBECTL) delete pvc --all --ignore-not-found || true
	@echo "🗑️  Step 3/6 — Removing stale operator namespaces (operators will be reinstalled)..."
	@kubectl --context=$(KUBE_CTX) delete namespace cert-manager rabbitmq-system \
		--ignore-not-found --timeout=120s || true
	@echo "⏳ Step 4/6 — Waiting for operator namespaces to fully terminate..."
	@$(MAKE) -s wait-operator-namespaces-gone
	@echo "🧼 Step 5/6 — Removing any accidentally committed vendor manifests..."
	@rm -rf vendor/
	@echo "♻️  Step 6/6 — Re-bootstrapping from Git..."
	@$(MAKE) -s bootstrap
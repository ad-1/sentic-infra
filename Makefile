NAMESPACE  := sentic
CLUSTER    := definition
KUBE_CTX   ?= minikube

KUBECTL    := kubectl --context=$(KUBE_CTX) -n $(NAMESPACE)

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
.PHONY: bootstrap
bootstrap: install-cert-manager install-cluster-operator install-topology-operator

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
	$(KUBECTL) apply -f definition.yaml

## Deploy queue topology (requires Messaging Topology Operator)
.PHONY: apply-topology
apply-topology:
	$(KUBECTL) apply -f topology/queues.yaml

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
	$(KUBECTL) delete -f definition.yaml

## Delete queue topology resources
.PHONY: delete-topology
delete-topology:
	$(KUBECTL) delete -f topology/queues.yaml

## Port-Forward: Opens the bridge (Blocking command) for the management UI (http://localhost:15672) and AMQP
.PHONY: port-forward
port-forward:
	@echo "🔌 Opening tunnel to RabbitMQ (Ctrl+C to stop)..."
	@$(KUBECTL) port-forward svc/$(CLUSTER) 5672:5672 15672:15672

## Repave: The Orchestrator
.PHONY: repave
repave:
	@echo "🧹 Step 1/5 — Tearing down (ignoring errors if not found)..."
	@$(KUBECTL) delete -f topology/queues.yaml --ignore-not-found
	@$(KUBECTL) delete -f definition.yaml --ignore-not-found
	
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
	@echo "👉 Run 'make port-forward' in a new terminal tab to access the UI at http://localhost:15672"

## Force-Repave: Wipes EVERYTHING including persistent data (PVCs)
.PHONY: repave-hard
repave-hard: delete-topology
	$(KUBECTL) delete rabbitmqcluster --all
	$(KUBECTL) delete pvc --all
	$(MAKE) apply
	@echo "🔥 Hard repave complete. All data wiped and infra reset."
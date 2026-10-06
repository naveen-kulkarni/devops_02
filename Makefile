CLUSTER ?= inference-lab
HTTP_PORT ?= 18080
K3S_IMAGE ?= rancher/k3s:v1.35.5-k3s1
NAMESPACE ?= inference
RELEASE ?= inference-api
REPLICAS ?= 3
IMAGE ?= inference-api:0.3.1
DURATION ?= 30
CONCURRENCY ?= 30
UPGRADE_DURATION ?= 90
INCIDENTS ?= 1 2 3

CONTEXT := k3d-$(CLUSTER)
KUBECTL := kubectl --context $(CONTEXT)
HELM := helm --kube-context $(CONTEXT)

export CLUSTER HTTP_PORT NAMESPACE RELEASE REPLICAS CONTEXT CONCURRENCY

.PHONY: up cluster ingress image postgres install loadtest upgrade verify down

up: cluster ingress image postgres install

cluster:
	@k3d cluster get $(CLUSTER) >/dev/null 2>&1 || k3d cluster create $(CLUSTER) \
		--image $(K3S_IMAGE) \
		--servers 1 --agents 0 \
		-p "$(HTTP_PORT):80@loadbalancer" \
		--k3s-arg "--disable=traefik@server:0" \
		--wait

ingress:
	$(KUBECTL) apply -f deploy/ingress-nginx.yaml
	$(KUBECTL) -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout 5m
	@until $(KUBECTL) get validatingwebhookconfiguration ingress-nginx-admission \
		-o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q .; do sleep 2; done

image:
	docker build -t $(IMAGE) app
	k3d image import $(IMAGE) -c $(CLUSTER)

postgres:
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n $(NAMESPACE) apply -f deploy/postgres.yaml
	$(KUBECTL) -n $(NAMESPACE) rollout status statefulset/postgres --timeout 5m

install:
	$(HELM) upgrade --install $(RELEASE) releases/inference-api-1.0.0.tgz \
		--namespace $(NAMESPACE) \
		--set replicaCount=$(REPLICAS) \
		--wait --timeout 5m
	@echo
	@echo "curl -H 'Host: inference.local' http://localhost:$(HTTP_PORT)/v1/generate"

loadtest:
	@DURATION=$(DURATION) ./scripts/loadtest.sh

upgrade:
	@out=$$(mktemp); \
	DURATION=$(UPGRADE_DURATION) ./scripts/loadtest.sh > $$out & \
	sleep 5; \
	$(HELM) upgrade $(RELEASE) chart/inference-api \
		--namespace $(NAMESPACE) \
		--set replicaCount=$(REPLICAS) \
		--set-string podAnnotations.deployedAt=$$(date +%s); \
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/$(RELEASE) --timeout 3m; \
	wait; \
	cat $$out; \
	rm -f $$out

verify:
	@./scripts/verify.sh $(INCIDENTS)

down:
	k3d cluster delete $(CLUSTER)

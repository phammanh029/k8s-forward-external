#!/usr/bin/env bash
# Test commands and verification script for the Gateway API FQDN EndpointSlice PoC

# Exit on error
set -e

echo "=== Step 1: Create a k3d cluster with default Traefik disabled ==="
k3d cluster create gateway-poc \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"

echo "=== Step 2: Install Gateway API CRDs ==="
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

echo "=== Step 3: Install Traefik with Kubernetes Gateway Provider enabled ==="
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace kube-system \
  --set providers.kubernetesGateway.enabled=true \
  --wait

echo "=== Step 4: Apply PoC Manifests ==="
kubectl apply -f 01-mock-external.yaml
kubectl apply -f 02-gateway-routing.yaml

echo "=== Step 5: Wait for Nginx Deployment to be ready ==="
kubectl rollout status deployment/nginx-external-deploy -n external-target --timeout=120s

echo "=== Step 6: Perform Verifications ==="

echo -e "\n--- Test A: Route through Gateway using Host 'test.localhost' ---"
echo "Expected: 200 OK from External Nginx (meaning FQDN resolution succeeded and Host was successfully rewritten)"
curl -i -H "Host: test.localhost" http://localhost:80/

echo -e "\n--- Test B: Access backend service directly with incorrect Host header ---"
echo "Expected: 404 Not Found - Host header mismatch"
kubectl run curl-test-404 --rm -i --tty --image=curlimages/curl --namespace=demo --restart=Never -- \
  curl -i -H "Host: test.localhost" http://nginx-external-svc.external-target.svc.cluster.local/

echo -e "\n--- Test C: Access backend service directly with correct Host header ---"
echo "Expected: 200 OK from External Nginx"
kubectl run curl-test-200 --rm -i --tty --image=curlimages/curl --namespace=demo --restart=Never -- \
  curl -i -H "Host: nginx.localhost" http://nginx-external-svc.external-target.svc.cluster.local/

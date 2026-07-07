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
kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml

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

# Dynamically fetch the Traefik LoadBalancer External IP
echo "Fetching Traefik LoadBalancer External IP..."
INGRESS_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' || echo "")

# If external IP is empty or resolved as localhost, fallback to 127.0.0.1 (common in Docker Desktop environments)
if [ -z "$INGRESS_IP" ] || [ "$INGRESS_IP" = "localhost" ]; then
  echo "LoadBalancer IP is empty or localhost. Falling back to 127.0.0.1"
  INGRESS_IP="127.0.0.1"
else
  echo "Traefik LoadBalancer IP detected: $INGRESS_IP"
fi

echo -e "\n--- Test A: Route through Gateway using Host 'test.localhost' ---"
echo "Expected: 200 OK from External Nginx (meaning FQDN resolution succeeded and Host was successfully rewritten)"
curl -i -H "Host: test.localhost" http://$INGRESS_IP:80/

echo -e "\n--- Test B: Access backend service directly with incorrect Host header ---"
echo "Expected: 404 Not Found - Host header mismatch"
kubectl run curl-test-404 --rm -i --tty --image=curlimages/curl --namespace=demo --restart=Never -- \
  curl -i -H "Host: test.localhost" http://nginx-external-svc.external-target.svc.cluster.local/

echo -e "\n--- Test C: Access backend service directly with correct Host header ---"
echo "Expected: 200 OK from External Nginx"
kubectl run curl-test-200 --rm -i --tty --image=curlimages/curl --namespace=demo --restart=Never -- \
  curl -i -H "Host: nginx.localhost" http://nginx-external-svc.external-target.svc.cluster.local/

# ==============================================================================
# OPTIONAL: HOW TO VERIFY HTTPS (TLS) ROUTING PATH
# ==============================================================================
#
# If you want to test routing to the mock external service over HTTPS:
#
# 1. Generate a self-signed TLS certificate for 'nginx.localhost':
#    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
#      -keyout tls.key -out tls.crt \
#      -subj "/CN=nginx.localhost"
#
# 2. Create the TLS Secret in the 'external-target' namespace:
#    kubectl create secret tls nginx-external-tls \
#      -n external-target --key tls.key --cert tls.crt
#
# 3. Create the CA validation Secret in the 'demo' namespace (trust store for Traefik):
#    kubectl create secret generic external-ca-cert \
#      -n demo --from-file=ca.crt=tls.crt
#
# 4. Edit '01-mock-external.yaml' to uncomment:
#    - Nginx HTTPS server block (port 443) in the ConfigMap
#    - Port 443 definition, volumeMounts, and volumes in the Deployment
#    - Port 443 in the Service
#
# 5. Edit '02-gateway-routing.yaml' to:
#    - Uncomment port 443 in the EndpointSlice and the Headless Service
#    - Change HTTPRoute backendRefs port from 80 to 443
#    - Uncomment the BackendTLSPolicy resource at the end of the file
#
# 6. Re-apply the manifests:
#    kubectl apply -f 01-mock-external.yaml
#    kubectl apply -f 02-gateway-routing.yaml
#
# 7. Test using the dynamic INGRESS_IP:
#    curl -i -H "Host: test.localhost" http://$INGRESS_IP/
#    (Expected: 200 OK from External Secure Nginx (HTTPS))


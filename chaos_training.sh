#!/bin/bash

# ==============================================================================
# SCRIPT: OPENSHIFT CHAOS 
# ==============================================================================
# AUTHOR:  Fernando Leitao
# PURPOSE: Troubleshooting Deep Dive
#
# RULES:
# 1. DO NOT READ THE CODE. The script is the "user" reporting a bug.
# 2. Use 'oc' commands to diagnose (describe, logs, events, get -o yaml).
# 3. Only check the SOLUTIONS (bottom of file) if you are truly stuck.
# ==============================================================================

# --- CONFIGURATION ---
TEST_IMAGE="registry.access.redhat.com/ubi8/httpd-24"
NS="chaos-lab"

# --- LOGGING & UTILS ---
LOG_FILE="/tmp/chaos_debug.log"
echo "--- NEW SESSION $(date) ---" > "$LOG_FILE"

log() { echo "[$(date +'%T')] [INFO] $1" >> "$LOG_FILE"; }

# 1. Execute silently (for successful setups)
silent_cmd() {
    log "SILENT EXEC: $@"
    eval "$@" >/dev/null 2>&1
}

# 2. Execute expecting failure (to simulate user errors)
user_action_cmd() {
    log "USER ACTION: $@"
    echo -e "${YELLOW}> User attempts: $@${NC}"
    eval "$@" 2>&1 | grep -v "violate PodSecurity" | grep -v "created"
}

# --- VISUALS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

function print_ticket {
    echo ""
    echo -e "${YELLOW}+-----------------------------------------------------------------------------+"
    echo -e "|  INCOMING SUPPORT TICKET                                                    |"
    echo -e "+-----------------------------------------------------------------------------+${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${YELLOW}+-----------------------------------------------------------------------------+${NC}"
    echo ""
}

function nuke_namespace {
    log "Running NUKE protocol..."
    echo -e "${RED}[SYSTEM] Cleaning up previous mess...${NC}"
    oc delete all,pvc,pv,quota,limits,networkpolicy,rolebindings,serviceaccounts,secrets,configmaps --all -n $NS --wait=false --grace-period=0 --force >/dev/null 2>&1
    
    # Remove Finalizers loop
    if oc get ns $NS >/dev/null 2>&1; then
        REMAINING=$(oc get all,pvc,configmap,secret,sa,rolebinding -n $NS -o name 2>/dev/null)
        if [ ! -z "$REMAINING" ]; then
            for RES in $REMAINING; do
                oc patch $RES -n $NS --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1
            done
            oc delete all --all -n $NS --force --grace-period=0 >/dev/null 2>&1
        fi
    fi
    oc new-project $NS >/dev/null 2>&1 || oc project $NS >/dev/null 2>&1
}

function setup_env { nuke_namespace; }

# ==============================================================================
# SCENARIOS
# ==============================================================================

function scenario_1 {
    print_ticket "FROM: Frontend Team\nSUBJECT: Service Blindness\n\nPods are up, but Service has no endpoints. Check the selector!"
    silent_cmd "oc create deployment nginx-1 --image=$TEST_IMAGE --replicas=2 -n $NS"
    silent_cmd "oc label deployment nginx-1 app=nginx-correct --overwrite -n $NS"
    silent_cmd "oc create service clusterip nginx-svc-1 --tcp=80:8080 -n $NS --dry-run=client -o yaml | sed 's/app: nginx-1/app: nginx-wrong/' | oc apply -f - -n $NS"
}

function scenario_2 {
    print_ticket "FROM: Junior Dev\nSUBJECT: Port Mismatch\n\nApp listens on 8080. Service sends to 80. Connection Refused."
    silent_cmd "oc create deployment httpd-2 --image=$TEST_IMAGE -n $NS"
    silent_cmd "oc create service clusterip httpd-svc-2 --tcp=80:80 -n $NS"
}

function scenario_3 {
    print_ticket "FROM: Architect\nSUBJECT: Named Port Typo\n\nService looks for targetPort 'http-web'. Pod uses 'web'."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: pod-named-port
  labels: {app: named-port}
spec:
  containers: [{name: main, image: $TEST_IMAGE, ports: [{name: web, containerPort: 8080}]}]
---
apiVersion: v1
kind: Service
metadata:
  name: svc-named-port
spec:
  selector: {app: named-port}
  ports: [{name: http, port: 80, targetPort: http-web}]
EOF
}

function scenario_4 {
    print_ticket "FROM: Marketing\nSUBJECT: Route 503\n\nRoute points to a non-existent Service name."
    silent_cmd "oc create deployment nginx-4 --image=$TEST_IMAGE -n $NS"
    silent_cmd "oc create service clusterip nginx-svc-4 --tcp=80:8080 -n $NS"
    silent_cmd "oc expose service nginx-svc-4 --name=nginx-route-4 -n $NS"
    silent_cmd "oc patch route nginx-route-4 --type='json' -p='[{\"op\": \"replace\", \"path\": \"/spec/to/name\", \"value\": \"nginx-svc-missing\"}]' -n $NS"
}

function scenario_5 {
    print_ticket "FROM: Security\nSUBJECT: NetPol Blocking\n\nNetworkPolicy 'deny-all' is dropping my traffic."
    silent_cmd "oc run backend-5 --image=$TEST_IMAGE --labels='app=backend' --expose --port=8080 -n $NS"
    silent_cmd "oc run frontend-5 --image=curlimages/curl --command -- sleep infinity -n $NS"
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF
}

function scenario_6 {
    print_ticket "FROM: DBA\nSUBJECT: Secret Key Mismatch\n\nPod wants key 'password', Secret has 'username'."
    silent_cmd "oc create secret generic db-secret-6 --from-literal=username=admin -n $NS"
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: app-secret-6}
spec:
  containers:
  - name: main
    image: $TEST_IMAGE
    env: [{name: DB_PASS, valueFrom: {secretKeyRef: {name: db-secret-6, key: password}}}]
EOF
}

function scenario_7 {
    print_ticket "FROM: Ops\nSUBJECT: Missing ConfigMap\n\nDeployment can't mount 'missing-config-map'."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata: {name: app-cm-7}
spec:
  selector: {matchLabels: {app: app-cm-7}}
  template:
    metadata: {labels: {app: app-cm-7}}
    spec:
      containers:
      - name: main
        image: $TEST_IMAGE
        volumeMounts: [{name: config, mountPath: /var/www/html/config}]
      volumes: [{name: config, configMap: {name: missing-config-map}}]
EOF
}

function scenario_8 {
    print_ticket "FROM: Storage\nSUBJECT: PVC Pending\n\nPVC requests invalid StorageClass 'ultra-fast-nvme-premium'."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-8}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
  storageClassName: "ultra-fast-nvme-premium"
EOF
}

function scenario_9 {
    print_ticket "FROM: Dev\nSUBJECT: ReadOnly FS Crash\n\nApp can't write to /run/httpd. Needs a volume."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: readonly-pod-9}
spec:
  containers:
  - name: main
    image: $TEST_IMAGE
    securityContext: {readOnlyRootFilesystem: true}
EOF
}

function scenario_10 {
    print_ticket "FROM: Billing Dept\nSUBJECT: Deployment Forbidden (Quota?)\n\nI created a Deployment 'app-quota-10', but no Pods are coming up.\nStatus remains at 0 replicas."
    silent_cmd "oc create quota strict-quota-10 --hard=pods=0 -n $NS"
    silent_cmd "oc create deployment app-quota-10 --image=$TEST_IMAGE -n $NS"
}

function scenario_11 {
    print_ticket "FROM: AI Research\nSUBJECT: Pod Blocked (CPU Limit)\n\nMy App 'fat-app-11' is stuck at 0 replicas.\nI requested 500m CPU. Why is the cluster ignoring me?"
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: LimitRange
metadata: {name: cpu-limit-11}
spec:
  limits: [{default: {cpu: 100m}, max: {cpu: 200m}, type: Container}]
EOF
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fat-app-11
spec:
  selector: {matchLabels: {app: fat-app-11}}
  replicas: 1
  template:
    metadata: {labels: {app: fat-app-11}}
    spec:
      containers:
      - name: main
        image: $TEST_IMAGE
        resources:
          requests:
            cpu: "500m"
EOF
}

function scenario_12 {
    print_ticket "FROM: Windows Admin\nSUBJECT: Node Affinity Stuck\n\nPod requires Windows OS nodes."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata: {name: alien-app-12}
spec:
  selector: {matchLabels: {app: alien}}
  template:
    metadata: {labels: {app: alien}}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions: [{key: kubernetes.io/os, operator: In, values: [windows]}]
      containers: [{name: main, image: $TEST_IMAGE}]
EOF
}

function scenario_13 {
    print_ticket "FROM: Ops\nSUBJECT: NodeSelector Stuck\n\nPod requires label 'env=mars'."
    silent_cmd "oc create deployment taint-app-13 --image=$TEST_IMAGE -n $NS"
    silent_cmd "oc patch deployment taint-app-13 -p '{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"env\":\"mars\"}}}}}' -n $NS"
}

function scenario_14 {
    print_ticket "FROM: Monitoring\nSUBJECT: Liveness Loop\n\nProbe checks /healthz (404). App runs on /."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: dying-pod-14}
spec:
  containers:
  - name: main
    image: $TEST_IMAGE
    ports: [{containerPort: 8080}]
    livenessProbe: {httpGet: {path: /healthz, port: 8080}, initialDelaySeconds: 5, periodSeconds: 5}
EOF
}

function scenario_15 {
    print_ticket "FROM: LB\nSUBJECT: Readiness Fail\n\nProbe waits for /tmp/ready file."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: unready-pod-15, labels: {app: unready}}
spec:
  containers:
  - name: main
    image: $TEST_IMAGE
    ports: [{containerPort: 8080}]
    readinessProbe: {exec: {command: [cat, /tmp/ready]}, initialDelaySeconds: 5, periodSeconds: 5}
EOF
}

function scenario_16 {
    print_ticket "FROM: Architect\nSUBJECT: Init Crash\n\nInit container exits with code 1."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: init-fail-16}
spec:
  initContainers: [{name: setup, image: busybox, command: ["sh", "-c", "exit 1"]}]
  containers: [{name: main, image: $TEST_IMAGE}]
EOF
}

function scenario_17 {
    print_ticket "FROM: Automation\nSUBJECT: Syntax Error\n\nCommand string malformed: ['sleep 3600']."
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: cmd-fail-17}
spec:
  containers: [{name: main, image: busybox, command: ["sleep 3600"]}]
EOF
}

function scenario_18 {
    print_ticket "FROM: Audit\nSUBJECT: RBAC Denied\n\nServiceAccount needs 'view' role."
    silent_cmd "oc create sa viewer-18 -n $NS"
    cat <<EOF | oc apply -n $NS -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: app-18}
spec:
  serviceAccountName: viewer-18
  containers: [{name: main, image: image-registry.openshift-image-registry.svc:5000/openshift/cli, command: ["sleep", "infinity"]}]
EOF
}

function scenario_19 {
    print_ticket "FROM: Root\nSUBJECT: SCC Forbidden\n\nPod requests 'privileged: true'. SA is default."
    user_action_cmd "oc run root-pod-19 --image=$TEST_IMAGE --overrides='{\"spec\": {\"containers\": [{\"name\": \"main\", \"image\": \"$TEST_IMAGE\", \"securityContext\": {\"privileged\": true}}]}}' -n $NS"
}

function scenario_20 {
    print_ticket "FROM: CI/CD\nSUBJECT: Image Pull Error\n\nDeployment pulling from bad private registry."
    silent_cmd "oc create deployment private-app-20 --image=example.com/private/image:latest -n $NS"
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

clear
echo "=================================================================="
echo "   OPENSHIFT CHAOS: EXPROBLEM SIMULATOR"
echo "=================================================================="
echo -e "${BLUE}--- NETWORKING ---${NC}"
echo " 1. Ghost Service"
echo " 2. Port Mismatch"
echo " 3. Named Port Typo"
echo " 4. Route 503"
echo " 5. NetPol Block"
echo ""
echo -e "${BLUE}--- CONFIG & STORAGE ---${NC}"
echo " 6. Secret Key Error"
echo " 7. ConfigMap Missing"
echo " 8. PVC Stuck Pending"
echo " 9. ReadOnly FS Crash"
echo ""
echo -e "${BLUE}--- SCHEDULING ---${NC}"
echo "10. Quota Rejection"
echo "11. LimitRange Rejection"
echo "12. Affinity Stuck"
echo "13. NodeSelector Stuck"
echo ""
echo -e "${BLUE}--- HEALTH & LIFECYCLE ---${NC}"
echo "14. Liveness Loop"
echo "15. Readiness Fail"
echo "16. Init Crash"
echo "17. Syntax Error"
echo ""
echo -e "${BLUE}--- SECURITY ---${NC}"
echo "18. RBAC Denied"
echo "19. SCC Forbidden"
echo "20. Image Pull Error"
echo ""
echo -e "${BLUE}--- UTILS ---${NC}"
echo "99. Clean Environment (Nuke)"
echo "=================================================================="
read -p "Select Option: " opt

if [[ $opt -eq 0 ]]; then exit; fi

# Special case for cleanup
if [[ $opt -eq 99 ]]; then
    nuke_namespace
    echo -e "${GREEN}[OK] Environment Cleaned. Exiting.${NC}"
    exit 0
fi

# Run normal scenario
setup_env

case $opt in
    1) scenario_1 ;; 
    2) scenario_2 ;; 
    3) scenario_3 ;; 
    4) scenario_4 ;;
    5) scenario_5 ;; 
    6) scenario_6 ;; 
    7) scenario_7 ;; 
    8) scenario_8 ;;
    9) scenario_9 ;; 
    10) scenario_10 ;; 
    11) scenario_11 ;; 
    12) scenario_12 ;;
    13) scenario_13 ;; 
    14) scenario_14 ;; 
    15) scenario_15 ;; 
    16) scenario_16 ;;
    17) scenario_17 ;; 
    18) scenario_18 ;; 
    19) scenario_19 ;; 
    20) scenario_20 ;;
    *) echo "Invalid Option"; exit ;;
esac

echo -e "\n${GREEN}[ACTION]${NC} The environment is broken. Go fix it!"


#!/bin/bash
#
#AUTOR:   Fernando Leitao (BigMilk)
#HARDWARE: RHEL 9.4+ (Minimal), 256GB RAM, 40 vCPUs, 512Gb SSD.
# To run the script, you need to elevate privileges for your user
#
# Save the file, change the permission and execute:
# chmod +x lab_ocp.sh
# ./lab_ocp.sh
#
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   echo "Elevating privileges..."
   exec sudo /bin/bash "$0" "$@"
fi

# ==============================================================================
# CONFIGURATION
# ==============================================================================

MASTERS=("ocp-lab-ctlplane-0" "ocp-lab-ctlplane-1" "ocp-lab-ctlplane-2")
WORKERS=("ocp-lab-worker-0" "ocp-lab-worker-1")

BASE_PATH="/home/fernando/.kcli/clusters/ocp-lab"
SSH_KEY="$BASE_PATH/auth/id_rsa"
KUBEADMIN_PASS_FILE="$BASE_PATH/auth/kubeadmin-password"
export KUBECONFIG="$BASE_PATH/auth/kubeconfig"
SSH_USER="core"
DOMAIN="ocp-lab.lab.example.com"
LOG_FILE="/var/log/lab-manager.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

touch "$LOG_FILE"
chmod 666 "$LOG_FILE"

log() {
    local msg="$1"
    local timestamp=$(date +'%H:%M:%S')
    echo -e "${BLUE}[$timestamp]${NC} $msg" | tee -a "$LOG_FILE"
}

get_vm_ip() {
    # Try to get IP with 2s timeout to avoid blocking virsh
    timeout 2s virsh domifaddr "$1" 2>/dev/null | grep ipv4 | awk '{print $4}' | cut -d'/' -f1 | head -n 1
}

# ==============================================================================
# ACTIONS
# ==============================================================================

start_lab() {
    log ">>> STARTING LAB..."
    for vm in "${MASTERS[@]}" "${WORKERS[@]}"; do
        state=$(timeout 2s virsh domstate "$vm" 2>/dev/null)
        if [[ "$state" == "running" ]]; then
            log "$vm is already running."
        else
            log "Starting $vm..."
            timeout 5s virsh start "$vm" >/dev/null 2>&1
        fi
    done
    log ">>> Wait for services to come up (API may take 5-10 min)."
}

# "Smart" shutdown function with timeout
shutdown_vm_safe() {
    local vm=$1
    local ip=$(get_vm_ip "$vm")

    if [ -z "$ip" ]; then
        log "⚠️  $vm no IP. Trying ACPI Shutdown..."
        timeout 5s virsh shutdown "$vm" >/dev/null 2>&1
    else
        # THE MAGIC: 'timeout 10s' kills SSH if it freezes
        log "Sending SSH command to $vm..."
        timeout 10s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY" "$SSH_USER@$ip" "sudo shutdown -h now" >/dev/null 2>&1

        local ret=$?
        if [ $ret -eq 0 ]; then
            log "${GREEN}Command sent to $vm.${NC}"
        elif [ $ret -eq 124 ]; then
            log "${RED}SSH TIMEOUT on $vm! Process froze. Trying ACPI...${NC}"
            timeout 5s virsh shutdown "$vm" >/dev/null 2>&1
        else
            log "${YELLOW}SSH Failure ($ret) on $vm. Trying ACPI...${NC}"
            timeout 5s virsh shutdown "$vm" >/dev/null 2>&1
        fi
    fi
}

stop_lab_safe() {
    log ">>> STARTING GRACEFUL SHUTDOWN (ANTI-FREEZE)"

    # 1. Shutdown everything in parallel
    for vm in "${WORKERS[@]}" "${MASTERS[@]}"; do
        shutdown_vm_safe "$vm" &
    done

    log "Commands sent. Waiting for shutdown processes..."
    wait # Wait for SSH commands to finish (they have timeouts now, so wait won't block)

    # 2. Monitoring with Time Limit
    log ">>> Monitoring VMs (Max 60s)..."
    local max_retries=12 # 12 * 5s = 60s
    local count=0

    while [ $count -lt $max_retries ]; do
        running_vms=$(virsh list --name --state-running | grep ocp-lab)

        if [ -z "$running_vms" ]; then
            log "${GREEN}✅ SUCCESS: All VMs shut down.${NC}"
            return
        fi

        vms_inline=$(echo "$running_vms" | tr '\n' ' ')
        echo -ne "${CYAN}Still running ($(( 60 - count * 5 ))s remaining):${NC} $vms_inline\r"
        sleep 5
        ((count++))
    done

    echo -e "\n${RED}⏰ TIME'S UP! Some VMs did not shut down gracefully.${NC}"
    read -p "Force shutdown (pull the plug) now? (Y/n) " choice
    if [[ "$choice" =~ ^[yY] || -z "$choice" ]]; then
        stop_lab_force
    else
        log "Operation canceled by user. VMs remain running."
    fi
}

stop_lab_force() {
    log "${RED}>>> FORCE KILL (DESTRUCTION)${NC}"
    for vm in "${WORKERS[@]}" "${MASTERS[@]}"; do
        log "Killing: $vm"
        timeout 5s virsh destroy "$vm" >/dev/null 2>&1
    done
    log "Lab force shut down."
}

status_lab() {
    echo -e "\n${BLUE}=== VIRTUAL MACHINES ===${NC}"
    virsh list --all | grep ocp-lab

    echo -e "\n${BLUE}=== OPENSHIFT CLUSTER ===${NC}"
    if timeout 5s oc get nodes >/dev/null 2>&1; then
        PASS=$(cat "$KUBEADMIN_PASS_FILE" 2>/dev/null || echo "N/A")

        echo -e "${GREEN}✅ API ONLINE${NC}"
        echo "User: kubeadmin | Pass: $PASS"
        echo "API:  https://api.$DOMAIN:6443"
        echo -e "\n>>> Nodes:"
        oc get nodes
    else
        echo -e "${RED}❌ API Offline${NC}"
    fi
}

# ==============================================================================
# MENU
# ==============================================================================
echo "============================================="
echo "   OCP LAB MANAGER v1.0                      "
echo "============================================="
echo "1. Start Lab"
echo "2. Check Status"
echo "3. Shutdown (Safe w/ Timeout)"
echo "4. Shutdown (Force)"
echo "5. Exit"
echo "============================================="
read -p "Option: " opt

case $opt in
    1) start_lab ;;
    2) status_lab ;;
    3) stop_lab_safe ;;
    4) stop_lab_force ;;
    5) exit 0 ;;
    *) echo "??";;

esac

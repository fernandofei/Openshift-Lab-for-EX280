# Local Openshift Lab for EX280

Here is a polished, "GitLab-ready" English version. I’ve structured it using Markdown best practices (code blocks, clear headers, notes) to make it professional yet approachable for other developers or for your future self.

I added a **"Future Plans"** section at the end since you mentioned you want to add scripts later.

-----

# 🚀 OpenShift Lab Setup Guide (Bare Metal / KCLI)

**Author:** Fernando Leitao (BigMilk)  
**Purpose:** Rapid deployment of an OpenShift Lab for EX280 study using KVM/Libvirt and `kcli`.

### 🖥️ Hardware Requirements

This guide assumes the following specs (or similar):

  * **OS:** RHEL 9.4+ (Minimal Install)
  * **RAM:** 256GB
  * **CPU:** Xeon E (40 vCPUs)
  * **Storage:** Dedicated 512GB SSD

-----

## ⚠️ Important Instructions

1.  Follow the **Phases** in the exact order.
2.  Pay close attention to **User Permissions** (Run as `ROOT` vs `YOUR_USER`).
3.  **Do not ignore Phase 4** (using `tmux`)—it saves you from connection drops.
4. Pull Secret
     | # Get it here: https://console.redhat.com/openshift/install/pull-secret
     | # Action: Click "Download pull secret" and save to ~/openshift_pull.json
     | ls -lh ~/openshift_pull.json



## Phase 1: Host Preparation

**Run as:** `ROOT` 🛡️
**Goal:** Install KVM, Libvirt, and configure storage.

```bash
# 1. Install Essential Packages
dnf update -y
dnf groupinstall -y "Virtualization Host"
dnf install -y bind-utils vim git wget tar tmux bash-completion

# 2. Enable Virtualization Services
systemctl enable --now libvirtd

# 3. Configure User Permissions
# Replace 'fernando' with your actual non-root username
usermod -aG libvirt,qemu fernando

# 4. Fix Storage Pool
# Ensure Libvirt knows where to save VM disks
virsh pool-define-as --name default --type dir \
   --target /var/lib/libvirt/images
virsh pool-build default
virsh pool-start default
virsh pool-autostart default
```

-----

## Phase 2: KCLI Configuration

**Run as:** `YOUR_USER` 👤
**Goal:** Install the deployment tool without unnecessary sudo usage.
*(Note: Log out of root before proceeding\!)*

```bash
# 1. Install KCLI
sudo dnf -y install dnf-plugins-core
sudo dnf -y copr enable karmab/kcli
sudo dnf -y install kcli

# 2. Configure KVM Host (NO SUDO)
# This generates the correct ~/.kcli/config.yml
kcli create host kvm -H 127.0.0.1 local

# Verify (Should return a list of pools):
kcli list pools

# 3. Generate SSH Keys (If you don't have them)
ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa

# 4. Pull Secret
# Download your Pull Secret from the Red Hat Hybrid Cloud Console 
# and save it as: ~/openshift_pull.json
```

-----

## Phase 3: Cluster Definition

**Goal:** Define the parameters for the EX280 Lab.
**File:** Create `~/ex280-lab.yaml`

```yaml
cluster: ocp-lab
version: stable

# Topology (3 Masters, 2 Workers)
ctlplanes: 3
workers: 2

# Resources (Assuming large host memory)
# 16GB RAM per node
memory_ctlplane: 16384
memory_worker: 16384
numcpus_ctlplane: 4
numcpus_worker: 4

# Network & Storage
network: default
domain: lab.example.com
disk_size: 50

# Credentials
pull_secret: openshift_pull.json
```

-----

## Phase 4: Bulletproof Execution (TMUX)

**Goal:** Run the installation safely. If SSH drops, the process continues.

```bash
# 1. Start a TMUX session
tmux new -s install-ocp

# 2. Start Deployment (Takes approx. 40 mins)
kcli create cluster openshift --paramfile ex280-lab.yaml

# TIP: If your connection drops, reconnect via SSH and run:
# tmux attach -t install-ocp
```

-----

## Phase 5: Post-Install & Environment

**Goal:** Make the `oc` command globally accessible and fix DNS for the console.

### 1\. Global Binary Setup

```bash
# Move 'oc' binary to path (Requires sudo)
sudo mv oc /usr/local/bin/
sudo chown root:root /usr/local/bin/oc
sudo restorecon -v /usr/local/bin/oc
sudo chmod 755 /usr/local/bin/oc
```

### 2\. DNS / Host Config

Map the Console/Ingress URL to a worker node IP.

```bash
# Get the IP of a worker node
kcli listvms

# Edit hosts file
sudo vim /etc/hosts

# Add the following line (Replace IP with your worker's IP):
192.168.122.142 console-openshift-console.apps.ocp-lab.lab.example.com oauth-openshift.apps.ocp-lab.lab.example.com
```

### 3\. User Environment (Permanent)

```bash
cat <<EOF >> ~/.bashrc

# Config OpenShift Lab
export KUBECONFIG=~/.kcli/clusters/ocp-lab/auth/kubeconfig
source <(oc completion bash)
EOF

# Apply changes
source ~/.bashrc

# Validate
oc get nodes
```

-----

## Phase 6: Total Destruction (Cleanup)

**Goal:** Delete VMs and Networks to free up RAM for the next lab.
**⚠️ WARNING:** This is irreversible.

```bash
# 1. Nuke the Cluster
# The --yes flag skips the confirmation prompt
kcli delete cluster ocp-lab --yes

# 2. Verify Cleanup (Check for zombie VMs)
kcli list vms
```

-----

## 🛠️ Extras & Troubleshooting

**Find installation logs:**

```bash
find ~ -name ".openshift_install.log"
```

**Watch installation in real-time:**

```bash
tail -f ~/.kcli/clusters/ocp-lab/.openshift_install.log
```

**Script to manage your lab:**

```bash
chmod +x lab_ocp.sh
./lab_ocp.sh
```

-----

**Added CHAOS SIMULATOR**

./chaos_training.sh

A list of 20 exercises, for different topics. 
Also, you have the answers.txt file, don't cheat, try and if you are stucked, use it.

```bash
==================================================================
   OPENSHIFT CHAOS: PROBLEM SIMULATOR
==================================================================
--- NETWORKING ---
 1. Ghost Service
 2. Port Mismatch
 3. Named Port Typo
 4. Route 503
 5. NetPol Block

--- CONFIG & STORAGE ---
 6. Secret Key Error
 7. ConfigMap Missing
 8. PVC Stuck Pending
 9. ReadOnly FS Crash

--- SCHEDULING ---
10. Quota Rejection
11. LimitRange Rejection
12. Affinity Stuck
13. NodeSelector Stuck

--- HEALTH & LIFECYCLE ---
14. Liveness Loop
15. Readiness Fail
16. Init Crash
17. Syntax Error

--- SECURITY ---
18. RBAC Denied
19. SCC Forbidden
20. Image Pull Error

--- UTILS ---
99. Clean Environment (Nuke)
==================================================================
```

**Added REMOTE ACCESS from laptop to your Lab**

Unlike standard port forwarding (-L), a SOCKS5 tunnel acts as a dynamic proxy,
allowing your browser to resolve internal OpenShift DNS names directly through 
the bastion host.

```
==================================================================
   OPENSHIFT LAB: REMOTE ACCESS SETUP (SOCKS5)
==================================================================
--- STEP 1: OPEN TUNNEL (TERMINAL) ---
 Command: ssh -D 1080 -q -C -N YOUR_USER@<BASTION_IP>
 Note:    Terminal will appear to hang. Do not close it.
          This opens a dynamic proxy on localhost:1080.

--- STEP 2: CONFIGURE BROWSER (FIREFOX) ---
 Menu:    Settings > Network Settings > Manual Proxy
 Host:    127.0.0.1
 Port:    1080 (Select SOCKS v5)
 DNS:     [X] Proxy DNS when using SOCKS v5
          ^-- (CRITICAL: Must be checked to resolve .lab domains)

--- STEP 3: VERIFY CONNECTION ---
 Target:  https://console-openshift-console.apps.ocp-lab...
 Success: Login page loads (ignore SSL warning).
 Failure: "Server Not Found" (Go back and fix DNS checkbox).
==================================================================

```

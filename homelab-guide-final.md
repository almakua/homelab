# Homelab Kubernetes — Guida Definitiva

> **Stack**: Proxmox (cluster) → Terraform → Ubuntu 24.04 → k3s → MetalLB → ingress-nginx → cert-manager → ArgoCD → WireGuard → Pi-hole → servizi
>
> **Hardware**:
> - `boromir`: Intel i7-7700HQ — IP `10.0.20.11` — 16GB RAM (nodo Proxmox A)
> - `gandalf`: Intel i7-7500U — IP `10.0.20.10` — 12GB RAM (nodo Proxmox B)
> - `aragorn`: NAS esterno — IP `10.0.20.12` — export NFS `/mnt/media`
> - IP pubblico: `95.110.183.54`
> - Dominio: `mbianchi.me` (DNS su Cloudflare)

---

## Layout finale

```
boromir (i7-7700HQ) — 10.0.20.11
  ├── k3s-cp-0       10.0.20.21   2 vCPU  4GB   40GB   control plane
  ├── k3s-cp-1       10.0.20.22   2 vCPU  4GB   40GB   control plane
  └── k3s-worker-0   10.0.20.23   4 vCPU  6GB   60GB   workload pesanti (node-role=heavy)

gandalf (i7-7500U) — 10.0.20.10
  ├── k3s-cp-2       10.0.20.24   2 vCPU  4GB   40GB   control plane
  ├── k3s-worker-1   10.0.20.25   2 vCPU  4GB   60GB   workload leggeri (node-role=light)
  └── home-assistant 10.0.20.26   2 vCPU  2GB   32GB   fuori dal cluster k8s

NAS (aragorn) — 10.0.20.12
  └── /mnt/media  (NFS export → consumato direttamente dai pod)

IP cluster:
  MetalLB ingress-nginx:    10.0.20.200
  MetalLB WireGuard VPN:    10.0.20.202
  MetalLB Pi-hole DNS:      10.0.20.201
```

---

## Architettura di rete

```
Internet → 95.110.183.54 → router → port forward:
  80/443 TCP  → 10.0.20.200 (ingress-nginx MetalLB)
  51820 UDP   → 10.0.20.202 (WireGuard MetalLB)

Servizi pubblici (no VPN richiesta):
  mbianchi.me            → sito web
  plex.mbianchi.me       → Plex media server
  ntfy.mbianchi.me       → notifiche push

Servizi VPN-only (whitelist ingress):
  argo.mbianchi.me       → ArgoCD
  home.mbianchi.me       → Homepage dashboard
  wg.mbianchi.me         → WireGuard UI
  pihole.mbianchi.me     → Pi-hole
  transmission.mbianchi.me
  radarr.mbianchi.me
  sonarr.mbianchi.me
  prowlarr.mbianchi.me
  bazarr.mbianchi.me
  grafana.mbianchi.me    → (da deployare)

DNS VPN: client WireGuard usano Pi-hole (10.0.20.201)
  che risolve *.mbianchi.me → 10.0.20.200 internamente
```

---

## Indice

1. [Prerequisiti tool locali](#1-prerequisiti-tool-locali)
2. [Cloudflare DNS](#2-cloudflare-dns)
3. [Proxmox — preparazione template Ubuntu](#3-proxmox--preparazione-template-ubuntu)
4. [Terraform — provisioning VM](#4-terraform--provisioning-vm)
5. [k3s — installazione cluster](#5-k3s--installazione-cluster)
6. [kubectl locale](#6-kubectl-locale)
7. [MetalLB — sostituzione ServiceLB](#7-metallb--sostituzione-servicelb)
8. [ArgoCD — bootstrap GitOps](#8-argocd--bootstrap-gitops)
9. [Struttura repo GitOps](#9-struttura-repo-gitops)
10. [cert-manager — TLS automatico](#10-cert-manager--tls-automatico)
11. [ingress-nginx — reverse proxy](#11-ingress-nginx--reverse-proxy)
12. [WireGuard — VPN](#12-wireguard--vpn)
13. [Pi-hole — DNS interno VPN](#13-pi-hole--dns-interno-vpn)
14. [Plex — media server](#14-plex--media-server)
15. [Stack media — Transmission, Radarr, Sonarr, Prowlarr, Bazarr](#15-stack-media)
16. [ntfy — notifiche push](#16-ntfy--notifiche-push)
17. [Homepage — dashboard](#17-homepage--dashboard)
18. [Sito web](#18-sito-web)
19. [Monitoring — Grafana + Prometheus](#19-monitoring--grafana--prometheus)
20. [Home Assistant su Proxmox](#20-home-assistant-su-proxmox)
21. [Operazioni quotidiane](#21-operazioni-quotidiane)

---

## 1. Prerequisiti tool locali

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# terraform
sudo apt install -y terraform

# chiave SSH dedicata al cluster
ssh-keygen -t ed25519 -f ~/.ssh/homelab_k8s -C "homelab-k8s" -N ""
```

---

## 2. Cloudflare DNS

Su Cloudflare → `mbianchi.me` → DNS → Records. Proxy **OFF** (nuvola grigia) su tutti.

```
A    mbianchi.me    95.110.183.54   OFF
A    *              95.110.183.54   OFF
A    vpn            95.110.183.54   OFF
```

> Proxy OFF è obbligatorio — il proxy Cloudflare interferisce con cert-manager HTTP-01 challenge e con WireGuard UDP.

---

## 3. Proxmox — preparazione template Ubuntu

I due nodi Proxmox sono in **cluster**, quindi i VMID sono globali. Il template va creato su ciascun nodo separatamente con VMID diversi.

### Nota VMID

- `boromir` → template VMID `9999`
- `gandalf` → template VMID `9000`

Il template è stato creato su `gandalf` e poi migrato su `boromir` con:

```bash
# Dalla shell di gandalf — migra il template su boromir
qm migrate 9000 boromir --online 0
# Questo copia il template su boromir come VMID 9000 e lo rimuove da gandalf

# Poi ricrea il template su gandalf con VMID 9000
# oppure usa un VMID diverso (9999) su boromir
```

### Crea template su ciascun nodo

```bash
# Esegui su BOROMIR (crea VMID 9999)
ssh root@10.0.20.11

cd /var/lib/vz/template/iso/
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

apt install -y libguestfs-tools
virt-customize -a noble-server-cloudimg-amd64.img --install qemu-guest-agent

qm create 9999 \
  --name ubuntu-2404-template \
  --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26 --agent enabled=1

qm importdisk 9999 noble-server-cloudimg-amd64.img local-lvm
qm set 9999 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9999-disk-0
qm set 9999 --boot c --bootdisk scsi0
qm set 9999 --ide2 local-lvm:cloudinit
qm set 9999 --serial0 socket --vga serial0
qm template 9999
exit
```

```bash
# Esegui su GANDALF (crea VMID 9000)
ssh root@10.0.20.10
# Stesso identico script ma con VMID 9000 e nome del file diverso
# (l'immagine è già stata scaricata dalla migrazione precedente,
#  ma se non fosse: wget l'immagine, apt install libguestfs-tools, ecc.)
```

### Permessi API token Proxmox

Esegui una sola volta da qualsiasi nodo (il cluster sincronizza):

```bash
pveum role add TerraformRole -privs \
  "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
   Pool.Allocate Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit \
   VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk \
   VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
   VM.Migrate VM.PowerMgmt SDN.Use \
   VM.GuestAgent.Audit VM.GuestAgent.Unrestricted"

pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role TerraformRole
pveum user token add terraform@pve terraform-token --privsep=0
# → annota token ID e secret
```

---

## 4. Terraform — provisioning VM

### `infra/terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
```

### `infra/terraform/variables.tf`

```hcl
variable "proxmox_endpoint" {
  type    = string
  default = "https://10.0.20.11:8006"
}

variable "proxmox_token" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  type = string
}

variable "vm_user" {
  type    = string
  default = "ubuntu"
}
```

### `infra/terraform/providers.tf`

```hcl
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_token
  insecure  = true
}
```

### `infra/terraform/main.tf`

```hcl
locals {
  # VMID template per nodo — boromir=9999, gandalf=9000
  templates = {
    "boromir" = 9999
    "gandalf" = 9000
  }

  vms = {
    "k3s-cp-0"     = { node = "boromir", ip = "10.0.20.21", cores = 2, memory = 4096, disk = 40 }
    "k3s-cp-1"     = { node = "boromir", ip = "10.0.20.22", cores = 2, memory = 4096, disk = 40 }
    "k3s-cp-2"     = { node = "gandalf", ip = "10.0.20.24", cores = 2, memory = 4096, disk = 40 }
    "k3s-worker-0" = { node = "boromir", ip = "10.0.20.23", cores = 4, memory = 6144, disk = 60 }
    "k3s-worker-1" = { node = "gandalf", ip = "10.0.20.25", cores = 2, memory = 4096, disk = 60 }
  }
}

resource "proxmox_virtual_environment_vm" "k3s_node" {
  for_each = local.vms

  name      = each.key
  node_name = each.value.node
  tags      = ["k3s", "ubuntu"]

  clone {
    vm_id = local.templates[each.value.node]
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  initialization {
    user_account {
      username = var.vm_user
      keys     = [var.ssh_public_key]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "10.0.20.1"
      }
    }

    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }
  }
}
```

### `infra/terraform/terraform.tfvars` (non in git)

```hcl
proxmox_token  = "terraform@pve!terraform-token=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ssh_public_key = "ssh-ed25519 AAAA... homelab-k8s"
```

### Applica

```bash
cd infra/terraform
terraform init
terraform plan
terraform apply
```

### Fix search domain Ubuntu

Dopo la creazione delle VM, rimuovi il search domain `mbianchi.me` che Proxmox/UniFi inietta nel netplan — causa problemi DNS nel cluster:

```bash
for ip in 10.0.20.21 10.0.20.22 10.0.20.23 10.0.20.24 10.0.20.25; do
  ssh -i ~/.ssh/homelab_k8s ubuntu@$ip \
    "sudo sed -i '/search:/d; /mbianchi.me/d' /etc/netplan/50-cloud-init.yaml && sudo netplan apply"
done
```

Installa anche `nfs-common` su tutti i nodi per i mount NFS:

```bash
for ip in 10.0.20.21 10.0.20.22 10.0.20.23 10.0.20.24 10.0.20.25; do
  ssh -i ~/.ssh/homelab_k8s ubuntu@$ip \
    'sudo apt-get update && sudo apt-get install -y nfs-common'
done
```

---

## 5. k3s — installazione cluster

### Control plane 0 (bootstrap)

```bash
K3S_CP0=10.0.20.21

ssh -i ~/.ssh/homelab_k8s ubuntu@$K3S_CP0 \
  'curl -sfL https://get.k3s.io | sudo sh -s - server \
    --cluster-init \
    --tls-san 10.0.20.20 \
    --tls-san 10.0.20.21 \
    --tls-san 10.0.20.22 \
    --tls-san 10.0.20.24 \
    --disable traefik \
    --disable servicelb \
    --node-ip 10.0.20.21'
```

> `--disable servicelb` è fondamentale — usiamo MetalLB al suo posto per preservare il vero source IP dei client.

### Recupera il token

```bash
K3S_TOKEN=$(ssh -i ~/.ssh/homelab_k8s ubuntu@10.0.20.21 \
  'sudo cat /var/lib/rancher/k3s/server/node-token')
```

### Control plane 1 e 2

```bash
ssh -i ~/.ssh/homelab_k8s ubuntu@10.0.20.22 \
  "curl -sfL https://get.k3s.io | sudo K3S_TOKEN=$K3S_TOKEN sh -s - server \
    --server https://10.0.20.21:6443 \
    --tls-san 10.0.20.20 \
    --disable traefik \
    --disable servicelb \
    --node-ip 10.0.20.22"

ssh -i ~/.ssh/homelab_k8s ubuntu@10.0.20.24 \
  "curl -sfL https://get.k3s.io | sudo K3S_TOKEN=$K3S_TOKEN sh -s - server \
    --server https://10.0.20.21:6443 \
    --tls-san 10.0.20.20 \
    --disable traefik \
    --disable servicelb \
    --node-ip 10.0.20.24"
```

### Worker 0 e 1

```bash
ssh -i ~/.ssh/homelab_k8s ubuntu@10.0.20.23 \
  "curl -sfL https://get.k3s.io | sudo K3S_TOKEN=$K3S_TOKEN sh -s - agent \
    --server https://10.0.20.21:6443 \
    --node-ip 10.0.20.23 \
    --node-label node-role=heavy"

ssh -i ~/.ssh/homelab_k8s ubuntu@10.0.20.25 \
  "curl -sfL https://get.k3s.io | sudo K3S_TOKEN=$K3S_TOKEN sh -s - agent \
    --server https://10.0.20.21:6443 \
    --node-ip 10.0.20.25 \
    --node-label node-role=light"
```

---

## 6. kubectl locale

```bash
ssh -i ~/.ssh/homelab_k8s ubuntu@10.0.20.21 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's/127.0.0.1/10.0.20.21/' > ~/.kube/config
chmod 600 ~/.kube/config

# Aggiungi al .bashrc
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

kubectl get nodes
# tutti devono essere Ready
```

---

## 7. MetalLB — sostituzione ServiceLB

MetalLB assegna IP reali ai LoadBalancer service, permettendo a ingress-nginx di vedere i veri source IP dei client (necessario per la whitelist VPN).

### Installa MetalLB via Helm (prima di ArgoCD)

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --version 0.14.8 \
  --wait

# Configura IP pool
kubectl apply -f - << 'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.0.20.200-10.0.20.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lan-pool
EOF
```

---

## 8. ArgoCD — bootstrap GitOps

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 7.6.12 \
  --wait

# Cambia il service da LoadBalancer a ClusterIP
# (ingress-nginx non è ancora installato, lo gestiamo dopo)
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"ClusterIP"}}'

# Recupera password iniziale
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
```

### Aggiungi il repo GitHub privato

```bash
kubectl apply -n argocd -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: homelab-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/TUO_USERNAME/homelab.git
  username: TUO_USERNAME
  password: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF
```

### Root Application

```bash
kubectl apply -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/TUO_USERNAME/homelab.git
    targetRevision: main
    path: argo/applications
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

---

## 9. Struttura repo GitOps

```
homelab/
├── infra/
│   └── terraform/          ← provisioning VM Proxmox
├── argo/
│   ├── bootstrap/
│   │   └── root-app.yaml   ← applicato manualmente una sola volta
│   ├── applications/       ← solo file Application ArgoCD (gestiti dalla root)
│   │   ├── cert-manager.yaml
│   │   ├── cert-manager-issuers.yaml
│   │   ├── ingress-nginx.yaml
│   │   ├── metallb.yaml
│   │   ├── metallb-config.yaml
│   │   ├── wireguard.yaml
│   │   ├── pihole.yaml
│   │   ├── plex.yaml
│   │   ├── transmission.yaml
│   │   ├── radarr.yaml
│   │   ├── sonarr.yaml
│   │   ├── prowlarr.yaml
│   │   ├── bazarr.yaml
│   │   ├── ntfy.yaml
│   │   ├── homepage.yaml
│   │   ├── website.yaml
│   │   └── monitoring.yaml
│   ├── infrastructure/
│   │   └── cert-manager-issuers/
│   │       └── issuers.yaml
│   └── apps/               ← manifest reali dei servizi
│       ├── wireguard/
│       ├── pihole/
│       ├── plex/
│       ├── transmission/
│       ├── radarr/
│       ├── sonarr/
│       ├── prowlarr/
│       ├── bazarr/
│       ├── ntfy/
│       ├── homepage/
│       ├── website/
│       └── monitoring/
```

### Aggiungere un nuovo servizio

```bash
# 1. Crea i manifest
mkdir -p argo/apps/nuovo-servizio
# crea deployment.yaml, service.yaml, ingress.yaml, ecc.

# 2. Crea l'Application che punta ai manifest
cat > argo/applications/nuovo-servizio.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nuovo-servizio
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/TUO_USERNAME/homelab.git
    targetRevision: main
    path: argo/apps/nuovo-servizio
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# 3. Commit e push — ArgoCD fa il resto
git add argo/
git commit -m "feat: add nuovo-servizio"
git push origin main
```

---

## 10. cert-manager — TLS automatico

### `argo/applications/cert-manager.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    targetRevision: v1.15.3
    chart: cert-manager
    helm:
      values: |
        installCRDs: true
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### `argo/applications/cert-manager-issuers.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager-issuers
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  project: default
  source:
    repoURL: https://github.com/TUO_USERNAME/homelab.git
    targetRevision: main
    path: argo/infrastructure/cert-manager-issuers
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 30s
        maxDuration: 5m
```

### `argo/infrastructure/cert-manager-issuers/issuers.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: tua@email.it
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: tua@email.it
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

> Usa sempre `letsencrypt-staging` per testare la configurazione. Passa a `letsencrypt-prod` solo quando tutto funziona — Let's Encrypt prod ha rate limit severi.

---

## 11. ingress-nginx — reverse proxy

### `argo/applications/ingress-nginx.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ingress-nginx
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://kubernetes.github.io/ingress-nginx
    targetRevision: 4.11.3
    chart: ingress-nginx
    helm:
      values: |
        controller:
          service:
            type: LoadBalancer
            loadBalancerIP: "10.0.20.200"
            externalTrafficPolicy: Local
          config:
            use-forwarded-headers: "true"
            compute-full-forwarded-for: "true"
  destination:
    server: https://kubernetes.default.svc
    namespace: ingress-nginx
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

> `externalTrafficPolicy: Local` è fondamentale per preservare il source IP reale dei client — necessario per le whitelist VPN.

### Annotation whitelist per servizi VPN-only

Ogni Ingress dei servizi interni deve avere questa annotation:

```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "10.42.0.0/16,10.0.20.0/24,10.8.0.0/24,10.0.10.0/24"
```

- `10.42.0.0/16` — pod network k3s (include il pod wg-easy che forwarda il traffico VPN)
- `10.0.20.0/24` — subnet cluster Proxmox
- `10.8.0.0/24` — subnet client WireGuard
- `10.0.10.0/24` — subnet LAN casa

### Ingress ArgoCD con whitelist

```yaml
# argo/apps/argocd-ingress/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.42.0.0/16,10.0.20.0/24,10.8.0.0/24,10.0.10.0/24"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [argo.mbianchi.me]
      secretName: argocd-tls
  rules:
    - host: argo.mbianchi.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

---

## 12. WireGuard — VPN

### `argo/apps/wireguard/deployment.yaml` (parti rilevanti)

```yaml
env:
  - name: WG_HOST
    value: "vpn.mbianchi.me"
  - name: WG_PORT
    value: "51820"
  - name: WG_DEFAULT_DNS
    value: "10.0.20.201"        # Pi-hole — risolve *.mbianchi.me internamente
  - name: WG_ALLOWED_IPS
    value: "10.0.20.0/24"       # solo traffico verso il cluster via VPN
  - name: PASSWORD_HASH
    valueFrom:
      secretKeyRef:
        name: wg-easy-secret
        key: password-hash
```

### `argo/apps/wireguard/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: wg-easy-vpn
  namespace: wireguard
  annotations:
    metallb.universe.tf/loadBalancerIPs: "10.0.20.202"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: wg-easy
  ports:
    - name: wireguard
      protocol: UDP
      port: 51820
      targetPort: 51820
```

### Secret (creare manualmente, non in git)

```bash
# Genera hash bcrypt della password
python3 -c "import bcrypt; print(bcrypt.hashpw(b'TUA_PASSWORD', bcrypt.gensalt()).decode())"

kubectl create secret generic wg-easy-secret \
  --namespace wireguard \
  --from-literal=password-hash='$2b$12$...'
```

### Port forwarding router

```
UDP 51820 → 10.0.20.202:51820
```

---

## 13. Pi-hole — DNS interno VPN

Pi-hole serve come DNS per i client WireGuard. Risolve `*.mbianchi.me` all'IP interno dell'ingress (`10.0.20.200`) invece che all'IP pubblico — questo permette al traffico VPN di raggiungere i servizi interni senza hairpin NAT.

### `argo/apps/pihole/service.yaml` (DNS service)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pihole-dns
  namespace: pihole
  annotations:
    metallb.universe.tf/loadBalancerIPs: "10.0.20.201"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: pihole
  ports:
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
```

### Secret Pi-hole (creare manualmente)

```bash
kubectl create secret generic pihole-secret \
  --namespace pihole \
  --from-literal=password='TUA_PASSWORD_PIHOLE'
```

### Configura record DNS interni

Dopo che Pi-hole è running, aggiungi i record per tutti i servizi:

```bash
kubectl -n pihole exec deploy/pihole -- bash -c '
cat > /etc/dnsmasq.d/02-custom-dns.conf << EOF
address=/argo.mbianchi.me/10.0.20.200
address=/wg.mbianchi.me/10.0.20.200
address=/plex.mbianchi.me/10.0.20.200
address=/pihole.mbianchi.me/10.0.20.200
address=/home.mbianchi.me/10.0.20.200
address=/transmission.mbianchi.me/10.0.20.200
address=/radarr.mbianchi.me/10.0.20.200
address=/sonarr.mbianchi.me/10.0.20.200
address=/prowlarr.mbianchi.me/10.0.20.200
address=/bazarr.mbianchi.me/10.0.20.200
address=/ntfy.mbianchi.me/10.0.20.200
address=/grafana.mbianchi.me/10.0.20.200
EOF
pihole restartdns
'
```

> Ogni volta che aggiungi un nuovo servizio, aggiungi il record DNS qui.

---

## 14. Plex — media server

### `argo/apps/plex/deployment.yaml` (parti rilevanti)

```yaml
containers:
  - name: plex
    image: plexinc/pms-docker:latest
    env:
      - name: PLEX_CLAIM
        valueFrom:
          secretKeyRef:
            name: plex-claim
            key: token
      - name: ADVERTISE_IP
        value: "https://plex.mbianchi.me:443/"
      - name: ALLOWED_NETWORKS
        value: "10.0.0.0/8,192.168.0.0/16,172.16.0.0/12"
    volumeMounts:
      - name: config
        mountPath: /config
      - name: media
        mountPath: /media
        readOnly: true
      - name: transcode
        mountPath: /transcode
volumes:
  - name: config
    persistentVolumeClaim:
      claimName: plex-config
  - name: media
    nfs:
      server: 10.0.20.12
      path: /mnt/media        # mount diretto NFS — vede tutta la struttura
      readOnly: true
  - name: transcode
    emptyDir:
      sizeLimit: 20Gi
```

> Il volume `media` monta **direttamente** il root dell'export NFS, non tramite StorageClass. Questo permette a Plex di vedere la struttura reale delle cartelle (`/media/movies`, `/media/series`, `/media/music`).

### Claim token (scade in 4 minuti!)

```bash
# 1. Vai su https://plex.tv/claim e copia il token
# 2. IMMEDIATAMENTE crea il secret e cancella il vecchio pod

kubectl create secret generic plex-claim \
  --namespace media \
  --from-literal=token='claim-XXXXXXXX'

kubectl -n media delete pod -l app=plex
# Il pod ripartirà e userà il claim prima che scada
```

### Librerie Plex

Dopo il primo avvio, aggiungi le librerie dall'UI:
- Movies → `/media/movies`
- TV Shows → `/media/series`
- Music → `/media/music`

---

## 15. Stack media

### Indirizzi interni cluster

| Servizio | URL interno (da usare nelle configurazioni) |
|----------|---------------------------------------------|
| Transmission | `http://transmission.media.svc.cluster.local:9091` |
| Radarr | `http://radarr.media.svc.cluster.local:7878` |
| Sonarr | `http://sonarr.media.svc.cluster.local:8989` |
| Prowlarr | `http://prowlarr.media.svc.cluster.local:9696` |
| Bazarr | `http://bazarr.media.svc.cluster.local:6767` |

### Ordine di configurazione

1. **Transmission** — configura cartelle download (`/downloads/complete`, `/downloads/incomplete`) e abilita auth
2. **Radarr** — aggiungi root folder `/movies`, configura Transmission come download client (category: `radarr`)
3. **Sonarr** — aggiungi root folder `/series`, configura Transmission (category: `sonarr`)
4. **Prowlarr** — aggiungi indexer, connetti a Radarr e Sonarr via API key
5. **Bazarr** — connetti a Radarr e Sonarr, configura provider sottotitoli (OpenSubtitles.com, Subscene)

### Volumi NFS media

Tutti i servizi media montano le cartelle NFS direttamente:

```yaml
volumes:
  - name: movies
    nfs:
      server: 10.0.20.12
      path: /mnt/media/movies
  - name: series
    nfs:
      server: 10.0.20.12
      path: /mnt/media/series
  - name: downloads
    nfs:
      server: 10.0.20.12
      path: /mnt/media/downloads
```

---

## 16. ntfy — notifiche push

### Configurazione iOS push

Per ricevere notifiche push native su iOS, ntfy usa `ntfy.sh` come gateway per APNs:

```yaml
# argo/apps/ntfy/configmap.yaml
data:
  server.yml: |
    base-url: "https://ntfy.mbianchi.me"
    auth-default-access: "deny-all"
    upstream-base-url: "https://ntfy.sh"   # gateway iOS push
    behind-proxy: true
```

### Crea utente admin

```bash
kubectl -n ntfy exec deploy/ntfy -- ntfy user add --role=admin admin
```

### Integrazione con Radarr/Sonarr

In Radarr/Sonarr: Settings → Connect → Add → ntfy:
- URL: `https://ntfy.mbianchi.me`
- Topic: `homelab-alerts`
- Username/Password: le tue credenziali ntfy

---

## 17. Homepage — dashboard

### Aggiornare i widget con le API key

Dopo aver configurato i servizi, aggiorna `argo/apps/homepage/configmap.yaml` con le API key reali:

```yaml
# In services.yaml del ConfigMap
- Radarr:
    widget:
      type: radarr
      url: http://radarr.media.svc.cluster.local:7878
      key: RADARR_API_KEY    # Settings → General → API Key

- Sonarr:
    widget:
      type: sonarr
      url: http://sonarr.media.svc.cluster.local:8989
      key: SONARR_API_KEY

- Prowlarr:
    widget:
      type: prowlarr
      url: http://prowlarr.media.svc.cluster.local:9696
      key: PROWLARR_API_KEY
```

Dopo la modifica:

```bash
git add argo/apps/homepage/configmap.yaml
git commit -m "feat: configure homepage API keys"
git push origin main
kubectl -n homepage rollout restart deployment homepage
```

---

## 18. Sito web

Il sito usa un'immagine Docker custom buildabile dal repo `https://github.com/almakua/minas_tirith`.

### Build e push manuale

```bash
cd ~/Projects
git clone https://github.com/almakua/minas_tirith.git
cd minas_tirith

echo "GITHUB_TOKEN" | docker login ghcr.io -u almakua --password-stdin

docker build -t ghcr.io/almakua/minas_tirith:latest .
docker push ghcr.io/almakua/minas_tirith:latest
```

### Secret per pull da ghcr.io privato

```bash
kubectl create secret docker-registry ghcr-secret \
  --namespace website \
  --docker-server=ghcr.io \
  --docker-username=almakua \
  --docker-password=GITHUB_TOKEN
```

### Aggiornare il sito

```bash
cd ~/Projects/minas_tirith
# modifica i file HTML/CSS/JS
docker build -t ghcr.io/almakua/minas_tirith:latest .
docker push ghcr.io/almakua/minas_tirith:latest

# Force pull della nuova immagine nel cluster
kubectl -n website rollout restart deployment website
```

---

## 19. Monitoring — Grafana + Prometheus

`kube-prometheus-stack` installa tutto il necessario: Prometheus (raccoglie metriche), Grafana (visualizzazione), Alertmanager (alert → ntfy), e tutti gli exporter per monitorare nodi e pod.

### `argo/applications/monitoring.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    targetRevision: 65.1.1
    chart: kube-prometheus-stack
    helm:
      values: |
        prometheus:
          prometheusSpec:
            retention: 15d
            retentionSize: "10GB"
            storageSpec:
              volumeClaimTemplate:
                spec:
                  storageClassName: local-path
                  accessModes: [ReadWriteOnce]
                  resources:
                    requests:
                      storage: 15Gi
            nodeSelector:
              node-role: heavy

        grafana:
          adminPassword: ""    # imposta via secret
          persistence:
            enabled: true
            storageClassName: local-path
            size: 5Gi
          ingress:
            enabled: true
            ingressClassName: nginx
            hosts: [grafana.mbianchi.me]
            tls:
              - secretName: grafana-tls
                hosts: [grafana.mbianchi.me]
            annotations:
              cert-manager.io/cluster-issuer: letsencrypt-prod
              nginx.ingress.kubernetes.io/whitelist-source-range: "10.42.0.0/16,10.0.20.0/24,10.8.0.0/24,10.0.10.0/24"

        alertmanager:
          alertmanagerSpec:
            storage:
              volumeClaimTemplate:
                spec:
                  storageClassName: local-path
                  accessModes: [ReadWriteOnce]
                  resources:
                    requests:
                      storage: 2Gi
            # Configura ntfy come receiver per gli alert
            config:
              global:
                resolve_timeout: 5m
              route:
                group_by: [alertname]
                group_wait: 30s
                group_interval: 5m
                repeat_interval: 12h
                receiver: ntfy
              receivers:
                - name: ntfy
                  webhook_configs:
                    - url: http://ntfy.ntfy.svc.cluster.local/homelab-alerts
                      http_config:
                        basic_auth:
                          username: admin
                          password: TUA_PASSWORD_NTFY

        nodeExporter:
          enabled: true

        kubeStateMetrics:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### Deploy

```bash
# Aggiungi il record DNS
kubectl -n pihole exec deploy/pihole -- bash -c '
echo "address=/grafana.mbianchi.me/10.0.20.200" >> /etc/dnsmasq.d/02-custom-dns.conf
pihole restartdns
'

# Commit e deploy via ArgoCD
git add argo/applications/monitoring.yaml
git commit -m "feat: add monitoring stack"
git push origin main

kubectl -n argocd patch application root --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Attendi — kube-prometheus-stack è pesante, ci vuole 5-10 minuti
watch "kubectl get pods -n monitoring"
```

### Accedi a Grafana

Vai su `https://grafana.mbianchi.me` (richiede VPN). Login: `admin` / password configurata.

Le dashboard pre-installate includono:
- **Kubernetes / Cluster** — overview CPU/RAM/disco
- **Kubernetes / Nodes** — dettaglio per nodo
- **Kubernetes / Pods** — metriche per pod
- **Node Exporter / Full** — metriche OS dettagliate

### Alert su ntfy

Alertmanager invia alert a ntfy automaticamente per:
- Nodo down
- Pod in CrashLoopBackOff
- Disco >80%
- CPU >90% sostenuto

---

## 20. Home Assistant su Proxmox

Home Assistant gira come VM dedicata su **gandalf** (`10.0.20.10`), completamente separata dal cluster k8s. Usa HAOS (Home Assistant Operating System) — stessa esperienza del Raspberry Pi, con aggiornamenti automatici e Add-on store completo.

Il dongle **Sonoff ZBDongle-E** è fisicamente attaccato a gandalf e viene passato alla VM tramite USB passthrough.

### Preparazione — trova il device ID del dongle

Dalla shell di gandalf, con il dongle attaccato:

```bash
ssh root@10.0.20.10

lsusb
# Cerca una riga tipo:
# Bus 001 Device 003: ID 10c4:ea60 Silicon Labs CP210x UART Bridge
#                         ^^^^ ^^^^
#                         vendor product

# Sonoff ZBDongle-E usa il chip Silicon Labs CP2102N
# vendor: 10c4  product: ea60
```

Annota `vendor:product` — nel caso del Sonoff ZBDongle-E è quasi certamente `10c4:ea60`.

### Scarica HAOS per KVM/Proxmox

```bash
ssh root@10.0.20.10

cd /var/lib/vz/template/iso/

# Scarica l'immagine HAOS in formato qcow2 per KVM
# Controlla l'ultima versione su https://github.com/home-assistant/operating-system/releases
# Cerca il file haos_ova-X.X.qcow2.xz

wget https://github.com/home-assistant/operating-system/releases/download/13.2/haos_ova-13.2.qcow2.xz

# Decomprimi
xz -d haos_ova-13.2.qcow2.xz
# Risulta: haos_ova-13.2.qcow2
```

### Crea la VM Home Assistant su Proxmox

Dalla UI di Proxmox su gandalf (`https://10.0.20.10:8006`):

**1. Crea una nuova VM** (Crea VM in alto a destra):

| Campo | Valore |
|-------|--------|
| Node | gandalf |
| VM ID | 200 |
| Name | home-assistant |
| OS | Do not use any media |
| System → SCSI Controller | VirtIO SCSI single |
| System → BIOS | OVMF (UEFI) |
| System → EFI Storage | local-lvm |
| Disks | **rimuovi** il disco di default — lo aggiungiamo dopo |
| CPU → Cores | 2 |
| CPU → Type | x86-64-v2-AES |
| Memory | 2048 MB |
| Network → Bridge | vmbr0 |
| Network → Model | VirtIO |

**2. Importa il disco qcow2**

Dalla shell di gandalf:

```bash
# Importa il disco HAOS nella VM 200 (local-lvm storage)
qm importdisk 200 /var/lib/vz/template/iso/haos_ova-13.2.qcow2 local-lvm

# L'output mostrerà qualcosa come:
# Successfully imported disk as 'unused0:local-lvm:vm-200-disk-1'
```

**3. Configura il disco importato**

Dalla UI → VM 200 → Hardware:
- Seleziona il disco `unused0` → **Edit**
- Bus/Device: `scsi0`
- Spunta **Discard** e **IO thread**
- **Add**

Poi Hardware → Boot Order:
- Spunta `scsi0` e mettilo primo nella lista

**4. Aggiungi USB passthrough del dongle Zigbee**

Con la VM **spenta**, dalla UI → VM 200 → Hardware → **Add** → **USB Device**:
- Seleziona **Use USB Vendor/Device ID**
- Vendor ID: `10c4`
- Device ID: `ea60`
- **Add**

In alternativa via CLI:

```bash
# Aggiungi alla config della VM 200
echo "usb0: host=10c4:ea60" >> /etc/pve/qemu-server/200.conf
```

### Avvia HAOS e configurazione iniziale

```bash
# Avvia la VM dalla UI di Proxmox
# oppure via CLI:
qm start 200
```

HAOS impiega circa 2-3 minuti per il primo avvio. Una volta avviata, è raggiungibile su:

```
http://10.0.20.26:8123
```

> **Nota**: HAOS assegna l'IP tramite DHCP. Assicurati che il tuo router DHCP assegni sempre `10.0.20.26` al MAC address della VM (puoi verificarlo in UniFi → Clients). In alternativa configura IP statico da HAOS: Settings → System → Network.

### Prima configurazione HAOS

1. Apri `http://10.0.20.26:8123` dal browser
2. Completa il wizard iniziale (nome, account, timezone Italia)
3. HAOS rileva automaticamente i dispositivi sulla rete

### Verifica il dongle Zigbee

Una volta dentro HAOS:

1. **Settings → System → Hardware** — verifica che il dongle sia visibile come `/dev/ttyUSB0` o `/dev/serial/by-id/usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_*`
2. Installa l'**Add-on Zigbee2MQTT** o usa l'integrazione **ZHA** (Zigbee Home Automation) nativa

**Con ZHA** (più semplice):
- Settings → Devices & Services → Add Integration → Zigbee Home Automation
- Device path: `/dev/ttyUSB0` (o il path che hai trovato)
- Submitter type: `znp` per il Sonoff ZBDongle-E (usa chip CC2652P)

**Con Zigbee2MQTT** (più flessibile, consigliato se hai molti dispositivi):
- Settings → Add-ons → Add-on Store → cerca Zigbee2MQTT
- Installa e configura con `serial.port: /dev/ttyUSB0`

### Accesso remoto da fuori casa

HAOS è accessibile via:

1. **Nabu Casa** (servizio ufficiale, ~6€/mese) — zero configurazione, include assistente vocale
2. **Via VPN WireGuard** — connetti la VPN e accedi a `http://10.0.20.26:8123`
3. **Ingress nginx** — esponi `ha.mbianchi.me` via whitelist VPN (vedi sotto)

**Opzione 3 — via ingress** (consigliata per coerenza con il resto):

```bash
mkdir -p argo/apps/homeassistant

cat > argo/apps/homeassistant/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homeassistant
  namespace: homeassistant
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.42.0.0/16,10.0.20.0/24,10.8.0.0/24,10.0.10.0/24"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    # HAOS usa WebSocket per real-time updates
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
spec:
  ingressClassName: nginx
  tls:
    - hosts: [ha.mbianchi.me]
      secretName: ha-tls
  rules:
    - host: ha.mbianchi.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homeassistant-external
                port:
                  number: 8123
EOF

# Service ExternalName che punta all'IP di HAOS fuori dal cluster
cat > argo/apps/homeassistant/service.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: homeassistant
---
apiVersion: v1
kind: Service
metadata:
  name: homeassistant-external
  namespace: homeassistant
spec:
  type: ExternalName
  externalName: "10.0.20.26"
  ports:
    - port: 8123
      targetPort: 8123
EOF
```

Aggiungi il DNS Pi-hole:

```bash
kubectl -n pihole exec deploy/pihole -- bash -c '
echo "address=/ha.mbianchi.me/10.0.20.200" >> /etc/dnsmasq.d/02-custom-dns.conf
pihole restartdns
'
```

Poi in HAOS devi aggiungere il dominio alla lista trusted proxies. Settings → System → Network → aggiorna `configuration.yaml` aggiungendo:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.42.0.0/16
    - 10.0.20.0/24
```

### Aggiornamenti HAOS

HAOS si aggiorna da solo — Settings → System → Updates. Non serve intervento manuale a meno di major version.

---

## 21. Operazioni quotidiane

### Deploy di una modifica

```bash
# Qualsiasi modifica al cluster
git add .
git commit -m "descrizione"
git push origin main
# ArgoCD applica automaticamente entro 3 minuti
# oppure forza subito:
kubectl -n argocd patch application root --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Stato del cluster

```bash
# Panoramica ArgoCD
kubectl -n argocd get applications

# Pod di tutti i namespace
kubectl get pods -A

# Risorse nodi
kubectl top nodes
kubectl top pods -A
```

### Aggiornare un servizio

Modifica il tag dell'immagine nel manifest, commit, push. ArgoCD fa il rolling update:

```yaml
# Prima
image: lscr.io/linuxserver/radarr:5.13.1
# Dopo
image: lscr.io/linuxserver/radarr:5.14.0
```

### Aggiungere un record DNS Pi-hole

```bash
kubectl -n pihole exec deploy/pihole -- bash -c '
echo "address=/nuovo-servizio.mbianchi.me/10.0.20.200" >> /etc/dnsmasq.d/02-custom-dns.conf
pihole restartdns
'
```

> Nota: i record Pi-hole **non sono persistenti** tra restart del pod. Per renderli persistenti mettili in un ConfigMap montato in `/etc/dnsmasq.d/`.

### Troubleshooting

```bash
# Pod non parte
kubectl describe pod <nome> -n <namespace>
kubectl logs <nome> -n <namespace>

# Certificato non emesso
kubectl describe certificate <nome> -n <namespace>
kubectl -n cert-manager logs -l app=cert-manager --tail=50

# Ingress non raggiungibile
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=30

# DNS non risolve
dig @10.0.20.201 <dominio>.mbianchi.me

# Verifica whitelist VPN
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=20
# controlla il source IP nelle righe di log

# ArgoCD non sincronizza
kubectl -n argocd get application <nome> -o yaml | grep -A10 "status:"
```

### Disastro recovery

```bash
# Distruggi e ricrea tutto (le VM)
cd infra/terraform
terraform destroy -auto-approve
terraform apply -auto-approve

# Reinstalla k3s (vedi sezione 5)
# Reinstalla MetalLB (vedi sezione 7)
# Reinstalla ArgoCD (vedi sezione 8)
# kubectl apply -f argo/bootstrap/root-app.yaml
# ArgoCD ricrea tutto il resto dal repo
```

---

> **Note finali**:
> - I secret (plex-claim, wg-easy-secret, pihole-secret, ghcr-secret) sono creati manualmente e NON sono in git. Conserva le credenziali in un password manager.
> - I record DNS Pi-hole si perdono al restart del pod — vedi nota nella sezione DNS.
> - Per il sito web, ogni aggiornamento richiede build manuale e `rollout restart`. Per automazione futura, valuta GitHub Actions.

# MC-DR Orchestrator

Multi-cloud disaster recovery system with GCP as primary and Azure as standby. Automates failover, failback, and health monitoring across two clouds using Terraform-managed GKE and AKS clusters with containerized Postgres.

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │       Cloud DNS (GCP)        │
                    │   api.yourdomain.com → GKE   │
                    └────────────┬────────────────┘
                                 │ normal traffic
              ┌──────────────────▼───────────────────┐
              │         GKE (us-central1-a)           │
              │           PRIMARY cluster              │
              │  - zonal (free management fee)        │
              │  - Postgres StatefulSet + PVC          │
              │  - Pub/Sub alerts via health_monitor   │
              └──────────────────────────────────────┘
                          ↕  failover/failback
              ┌──────────────────────────────────────┐
              │         AKS (eastus2)                │
              │           STANDBY cluster             │
              │  - autoscaler min=0 (idle cost ~$0)  │
              │  - Postgres StatefulSet + PVC          │
              │  - scales to 2 nodes on failover      │
              └──────────────────────────────────────┘
```

**Cost defaults (nodes at 0):** ~$0.84/month for persistent disk storage.
`terraform destroy` reaches true $0.

---

## Cost guards

All expensive resources default to off and require explicit opt-in:

| Resource | Default | Flag | Est. cost if on |
|---|---|---|---|
| Cross-cloud VPN | OFF | `enable_vpn = true` | ~$280/month |
| Cloud NAT | OFF | `enable_nat = true` | ~$32/month |
| GKE node pool | 0 nodes | scale.sh up | ~$25/month (e2-standard-2) |
| AKS node pool | 0 nodes | failover.py | ~$14/month (Standard_B2s) |
| Postgres PVC (GKE) | always on | n/a | ~$0.40/month (10Gi) |
| Postgres PVC (AKS) | always on | n/a | ~$0.44/month (10Gi) |

---

## Prerequisites

- `gcloud` CLI authenticated (`gcloud auth application-default login`)
- `az` CLI authenticated (`az login`)
- `terraform` >= 1.5
- `kubectl`
- Python 3.11+
- `ansible-core` >= 2.16 with the `kubernetes.core` collection (Postgres deploys; see `ansible/README.md`)

---

## First-time setup

### 1. Create GCP project

```bash
gcloud projects create YOUR_PROJECT_ID
gcloud config set project YOUR_PROJECT_ID
gcloud billing projects link YOUR_PROJECT_ID --billing-account=XXXXXX-XXXXXX-XXXXXX
```

### 2. Bootstrap GCS state bucket and enable APIs

```bash
./scripts/bootstrap_gcs.sh YOUR_PROJECT_ID us-central1
```

### 3. Configure variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — required fields:
#   gcp_project_id, azure_subscription_id
#   gcp_billing_account_id (optional — enables billing budget alert)
# The Postgres password is not a Terraform variable; export DB_MASTER_PASSWORD
# in your shell before the Ansible deploy step below.
```

`terraform.tfvars` is gitignored. Never commit it.

### 4. Initialize and apply

```bash
cd terraform
terraform init -backend-config="bucket=mc-dr-terraform-state-YOUR_PROJECT_ID"
terraform plan
terraform apply
```

### 5. Deploy Postgres with Ansible

Terraform owns cluster infrastructure only. Postgres StatefulSets are deployed
to both clusters (one playbook, one inventory, two clouds) through the
Kubernetes API:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
export DB_MASTER_PASSWORD=<password>

ansible-playbook deploy_postgres.yml                     # both clusters
ansible-playbook deploy_postgres.yml --limit gke-primary # one cluster
ansible-playbook deploy_postgres.yml --check --diff      # dry run / drift check
```

Run this right after `terraform apply` while the AKS standby is still running
(before `az aks stop`). Details and cold-standby caveats: `ansible/README.md`.

---

## Scaling clusters up/down

```bash
# Scale both clusters up (activates nodes)
./scripts/scale.sh up

# Scale both clusters back to 0 (idle, PVC retained)
./scripts/scale.sh down
```

---

## DR operations

### Health monitoring

Monitors the GKE primary endpoint. Alerts via Pub/Sub and Slack on 3 consecutive failures.

```bash
export GCP_PROJECT_ID=your-project-id
export PUBSUB_TOPIC_ID=mc-dr-dr-alerts
export PRIMARY_URL=https://api.yourdomain.com/healthz

python scripts/health_monitor.py
```

### Failover (GKE → AKS)

Scales up AKS, flips Cloud DNS to AKS LoadBalancer IP, publishes event.

```bash
python scripts/failover.py \
  --gcp-project YOUR_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks \
  --aks-ingress-ip AZURE_LB_IP

# Dry run (no changes):
python scripts/failover.py ... --dry-run
```

### Failback (AKS → GKE)

Verifies GKE is stable (5 consecutive checks), flips DNS back, scales AKS to 0.

```bash
python scripts/failback.py \
  --gcp-project YOUR_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --gke-ingress-ip GKE_LB_IP \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks

# Dry run:
python scripts/failback.py ... --dry-run
```

---

## Repository layout

```
mc-dr-orchestrator/
├── terraform/
│   ├── main.tf               # Root: GKE, AKS, Pub/Sub, Cloud Monitoring, VPN (gated)
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf          # GCS backend
│   └── modules/
│       ├── gcp/vpc/          # VPC, Cloud NAT (gated), HA VPN gateway
│       ├── gcp/gke/          # Zonal GKE cluster
│       ├── azure/vnet/       # VNet, subnets, NSG
│       └── azure/aks/        # AKS cluster, Log Analytics
├── ansible/
│   ├── inventory/hosts.yml   # gke-primary + aks-standby (kubeconfig contexts)
│   ├── templates/            # Single Jinja2 manifest source for both clouds
│   ├── deploy_postgres.yml   # API-driven Postgres deploy via kubernetes.core
│   └── render_manifests.yml  # Render templates for CI validation
├── functions/
│   └── billing_stopper/      # Cloud Function: disables billing at 100% budget
├── scripts/
│   ├── bootstrap_gcs.sh      # One-time GCS bucket + API enablement
│   ├── scale.sh              # Scale nodes up/down without applying Terraform
│   ├── health_monitor.py     # Continuous GKE health check; alerts via Pub/Sub
│   ├── failover.py           # GKE → AKS cutover
│   └── failback.py           # AKS → GKE restore
├── docs/
│   ├── runbooks/
│   │   ├── failover.md
│   │   ├── failback.md
│   │   └── cost-management.md
│   └── architecture.md
└── .github/workflows/
    └── deploy.yml            # CI: terraform validate, script lint, ansible-lint + rendered-manifest validation
```

---

## Observability

Custom Cloud Monitoring metrics under `custom.googleapis.com/dr/`:

| Metric | Description |
|---|---|
| `PrimaryHealthy` | 1 = healthy, 0 = failed |
| `PrimaryLatencyMs` | Response time in milliseconds |
| `ConsecutiveFailures` | Rolling failure count |
| `FailoverCompleted` | 1 = success, 0 = failed |
| `FailoverDurationSeconds` | Time to complete failover |
| `FailbackCompleted` | 1 = success, 0 = failed |
| `FailbackDurationSeconds` | Time to complete failback |

Pub/Sub topic `mc-dr-dr-alerts` receives all health and DR events.

---

## Security notes

- `terraform.tfvars` is gitignored; keep it that way (project and billing identifiers)
- Postgres credentials are injected as a Kubernetes Secret by Ansible from the `DB_MASTER_PASSWORD` environment variable (`no_log`, asserted non-empty, never committed)
- GKE: private nodes, Workload Identity, Shielded VMs, Calico network policy
- AKS: Azure AD RBAC, managed identity, Log Analytics
- Billing budget alert at $50/month with thresholds at 50%, 90%, 100%

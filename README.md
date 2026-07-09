# Multi-Cloud Disaster Recovery Orchestrator

Automated failover between AWS (primary) and Azure (standby) with sub-15-minute RTO and sub-60-second RPO. Infrastructure-as-code via Terraform, Python orchestration scripts, Chaos Mesh testing, and Grafana observability.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AWS (Primary)                               │
│                                                                     │
│  Route53 (Failover DNS)                                             │
│       │                                                             │
│  ALB / NLB ──► EKS Cluster (3+ nodes, 3 AZs)                      │
│                     │                                               │
│              RDS PostgreSQL (Multi-AZ)                              │
│                     │ pglogical logical replication                 │
│                     │                                               │
│  ◄──── Site-to-Site VPN (IKEv2 + BGP) ────►                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                    health_monitor.py
                    (polls every 30s)
                              │
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure (Standby)                              │
│                                                                     │
│  AKS Cluster — app nodepool at 0 nodes (zero cost at rest)         │
│                     │                                               │
│         Azure Database for PostgreSQL Flexible Server               │
│         (receives pglogical replication from AWS)                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Failover Flow

```
Primary fails 3 checks (90s)
        │
        ▼
health_monitor.py triggers failover.py
        │
        ├── 1. Scale AKS: 0 → 3 nodes         (~4 min)
        ├── 2. Deploy workloads to AKS         (~2 min)
        ├── 3. Promote Azure PostgreSQL        (<30s)
        ├── 4. Update Route53 DNS              (~2 min)
        └── 5. Notify via SNS/Slack
                                               ─────────
                                               Total: ~8–10 min
```

---

## Repository Structure

```
multi-cloud-dr-orchestrator/
├── terraform/
│   ├── providers.tf          # AWS + Azure provider config
│   ├── main.tf               # Root module — wires everything together
│   ├── variables.tf
│   ├── outputs.tf            # Includes ready-to-paste .env block
│   └── modules/
│       ├── aws/
│       │   ├── vpc/          # VPC, subnets, NAT GWs, flow logs
│       │   ├── eks/          # EKS cluster, node groups, IRSA, CA
│       │   ├── rds/          # PostgreSQL with pglogical params, secrets, alarms
│       │   └── vpn/          # Customer GW, VGW, site-to-site VPN
│       └── azure/
│           ├── vnet/         # VNet, subnets, NSGs, private DNS
│           ├── aks/          # AKS with zero-node app pool, Log Analytics
│           ├── postgresql/   # Flexible Server with pglogical config
│           └── vpn/          # Zone-redundant VPN GW, active-active BGP
├── scripts/
│   ├── health_monitor.py     # Polls primary, triggers failover on 3 failures
│   ├── failover.py           # Orchestrates AWS→Azure failover (full/db/app)
│   ├── failback.py           # Orchestrates Azure→AWS failback (manual only)
│   └── requirements.txt
├── chaos-experiments/
│   ├── network-partition.yaml  # Full + partial network partition chaos
│   └── pod-failure.yaml        # Pod kill, CPU stress, DNS failure
├── grafana/
│   └── dashboard.json          # DR dashboard (RTO, RPO, replication lag, health)
├── k8s/
│   ├── aws/                    # EKS namespace, deployment, HPA, PDB
│   └── azure/                  # AKS namespace, deployment, tolerations
├── .github/workflows/
│   └── deploy.yml              # Lint → Plan → Apply → Smoke test
└── runbooks/
    ├── automated-failover.md   # What happens automatically + manual fallback
    ├── manual-failback.md      # Step-by-step AWS recovery
    └── partial-failover.md     # DB-only and app-only failover scenarios
```

---

## Prerequisites

- AWS account with permissions for EKS, RDS, VPC, Route53, SNS, CloudWatch
- Azure subscription with permissions for AKS, PostgreSQL, VNet, VPN Gateway
- Terraform ≥ 1.7
- Python 3.12+
- AWS CLI v2 configured
- Azure CLI installed and logged in
- `kubectl` installed
- An S3 bucket for Terraform state + DynamoDB table for state locking

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/yourorg/multi-cloud-dr-orchestrator.git
cd multi-cloud-dr-orchestrator
```

Create `terraform/terraform.tfvars`:
```hcl
project_name          = "mc-dr"
environment           = "production"
aws_region            = "us-east-1"
azure_location        = "eastus"
azure_subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
azure_tenant_id       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
db_master_password    = "YourSecurePassword123!"
alert_email           = "oncall@yourorg.com"
route53_zone_id       = "ZXXXXXXXXXXXXX"
domain_name           = "yourapp.com"
```

### 2. Deploy infrastructure

```bash
cd terraform
terraform init

# Primary (AWS)
terraform workspace new primary
terraform apply -target=module.aws_vpc -target=module.aws_eks -target=module.aws_rds

# Standby (Azure) — after Azure VPN GW IP is known
terraform apply -target=module.azure_vnet -target=module.azure_aks -target=module.azure_postgresql

# VPN interconnect + DNS
terraform apply
```

### 3. Configure pglogical replication

```bash
# On AWS RDS (publisher)
psql -h $(terraform output -raw rds_endpoint) -U dbadmin -d appdb <<'EOF'
CREATE EXTENSION IF NOT EXISTS pglogical;
SELECT pglogical.create_node(
    node_name := 'aws_primary',
    dsn := 'host=RDS_ENDPOINT dbname=appdb user=dbadmin password=PASSWORD'
);
SELECT pglogical.create_replication_set('default');
SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);
SELECT pg_create_logical_replication_slot('replica_slot', 'pglogical');
EOF

# On Azure PostgreSQL (subscriber)
PGPASSWORD=$AZURE_PG_PASSWORD psql "host=$(terraform output -raw azure_postgresql_fqdn) dbname=appdb user=dbadmin sslmode=require" <<'EOF'
CREATE EXTENSION IF NOT EXISTS pglogical;
SELECT pglogical.create_node(
    node_name := 'replica_node',
    dsn := 'host=AZURE_PG_FQDN dbname=appdb user=dbadmin password=PASSWORD sslmode=require'
);
SELECT pglogical.create_subscription(
    subscription_name := 'aws_subscription',
    provider_dsn := 'host=RDS_ENDPOINT dbname=appdb user=dbadmin password=PASSWORD',
    replication_sets := ARRAY['default'],
    synchronize_data := true
);
EOF
```

### 4. Start the health monitor

```bash
cd scripts
pip install -r requirements.txt

# Copy the .env block from Terraform outputs
terraform -chdir=../terraform output health_monitor_env > .env

python health_monitor.py \
  --primary-url https://api.yourapp.com/healthz \
  --check-interval 30 \
  --failure-threshold 3
```

### 5. Run a Chaos Mesh DR test

```bash
# Install Chaos Mesh
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-testing --create-namespace

# Run the full DR workflow test
kubectl apply -f chaos-experiments/network-partition.yaml

# Watch the failover
kubectl get workflow -n chaos-testing -w

# Check results
kubectl logs -n chaos-testing -l app=verify
```

---

## Targets

| Metric | Target | How measured |
|--------|--------|-------------|
| RTO | < 15 minutes | Time from first failed check → DNS resolves to Azure |
| RPO | < 60 seconds | Replication lag at time of failover (pglogical lag metric) |
| Standby cost | ~$50–80/month | AKS at 0 nodes; only control plane + PostgreSQL server |
| Health check interval | 30 seconds | Configurable via `--check-interval` |
| Failover trigger | 3 consecutive failures | ~90s detection window |

---

## Grafana Dashboard

Import `grafana/dashboard.json` into your Grafana instance. Configure two data sources:

1. **AWS CloudWatch** — namespace `DR/HealthMonitor` and `DR/Failover`
2. **Azure Monitor** — resource group `mc-dr-dr-rg`

Panels included: primary health, consecutive failures, last failover event, active cloud, RTO gauge, RPO/replication lag gauge, endpoint latency, VPN tunnel state, RDS CPU, EKS/AKS node counts, failover history table.

---

## Suggested Enhancements

The following improvements would make this system meaningfully more robust:

**1. Replace Python health monitor with Lambda + EventBridge**
The current monitor is a long-running process that itself becomes a single point of failure. Replacing it with an AWS Lambda on a 1-minute EventBridge schedule gives you managed availability, automatic retries, and CloudWatch Logs without running a server.

**2. Use AWS Global Accelerator instead of Route53 failover**
Route53 DNS failover has an inherent TTL lag (even at TTL=60, clients cache). Global Accelerator provides anycast IP-level failover in seconds, not minutes — this alone could cut your RTO by 2–3 minutes.

**3. Terraform `prevent_destroy` + state locking enforcement**
Add `lifecycle { prevent_destroy = true }` to RDS and AKS resources and enforce state locking via the DynamoDB table to prevent accidental destruction of live DR infrastructure.

**4. Store failover state in DynamoDB, not in-memory**
The current health monitor tracks `FAILOVER_TRIGGERED` in process memory. If the monitor process restarts, it loses this state and could double-trigger. A DynamoDB item with the current failover state is the correct solution.

**5. Automated chaos testing on a schedule**
The Chaos Mesh experiment currently requires manual triggering. Use the `scheduler.cron` field in the Chaos Mesh workflow to run a DR test monthly in a low-traffic window, with automatic pass/fail reporting to Slack.

**6. pglogical → AWS DMS for more reliable cross-cloud replication**
pglogical over a VPN can suffer intermittent reconnects. AWS Database Migration Service (DMS) with CDC mode is purpose-built for heterogeneous, cross-network replication and handles reconnects more gracefully.

**7. Separate Terraform workspaces with workspace-specific backends**
Currently both clouds share one tfstate file. Separating AWS and Azure into independent workspaces with separate S3 keys prevents a failed Azure apply from blocking an AWS change.

**8. mTLS between EKS and AKS during split-brain scenarios**
If both clusters are briefly live simultaneously (app-only failover), requests could reach either. Adding mTLS with a shared certificate authority and cluster-identity headers lets the DB reject writes from the "wrong" cluster.

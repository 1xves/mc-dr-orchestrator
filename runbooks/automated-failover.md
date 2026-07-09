# Runbook: Automated Failover (AWS → Azure)

**Severity:** P1
**RTO Target:** < 15 minutes
**RPO Target:** < 60 seconds
**Last reviewed:** 2024-01-01
**Owner:** On-call SRE

---

## Overview

This runbook documents the automated failover process from AWS (primary) to Azure (standby). Failover is triggered automatically by `health_monitor.py` after 3 consecutive failed health checks (~90 seconds). This document explains what happens automatically, how to verify success, and how to intervene if automation fails.

---

## Trigger Conditions

Failover is triggered when ALL of the following are true:

- The primary endpoint (`https://api.<domain>/healthz`) returns non-200 OR times out for **3 consecutive checks** (90 seconds)
- The health monitor process is running on the monitoring host
- No prior failover is already in progress (`FAILOVER_TRIGGERED=false`)

---

## Automated Sequence (what the system does)

| # | Step | Script | Expected Duration |
|---|------|--------|------------------|
| 1 | Detect 3 consecutive failures | `health_monitor.py` | 90s |
| 2 | Send SNS alert: failover initiated | `health_monitor.py` | <5s |
| 3 | Scale AKS app node pool: 0 → 3 nodes | `failover.py` | 3–5 min |
| 4 | Wait for AKS nodes to be Ready | `failover.py` | included |
| 5 | Apply Kubernetes manifests to AKS | `failover.py` | 1–2 min |
| 6 | Promote Azure PostgreSQL (drop pglogical) | `failover.py` | <30s |
| 7 | Update Route53 DNS to Azure LB IP | `failover.py` | 1–2 min |
| 8 | Send SNS alert: failover complete + RTO | `health_monitor.py` | <5s |

**Total automated RTO: ~8–12 minutes**

---

## On-Call Actions During Automated Failover

### Step 1 — Acknowledge the alert

When you receive the SNS/Slack alert:

```bash
# Verify alert is legitimate — check the monitor log
ssh monitor-host
tail -f /var/log/dr-monitor/health_monitor.log
```

### Step 2 — Watch the Grafana dashboard

Open: `https://grafana.internal/d/mc-dr-dashboard`

Check:
- **Primary Endpoint Health** → should be RED (DOWN)
- **Consecutive Failures** → should be ≥ 3
- **AKS Node Count** → should be climbing from 0 to 3
- **Active Cloud** → will flip to "Azure (DR)" when DNS propagates

### Step 3 — Verify Azure is serving traffic

```bash
# DNS should point to Azure within ~2 minutes of failover
dig api.<domain> +short

# Curl the endpoint directly to Azure LB (bypass DNS cache)
curl -sf --resolve api.<domain>:443:<AZURE_LB_IP> https://api.<domain>/healthz
```

### Step 4 — Verify database is promoted

```bash
# Connect to Azure PostgreSQL
PGPASSWORD=$AZURE_PG_PASSWORD psql \
  "host=$AZURE_PG_FQDN dbname=appdb user=dbadmin sslmode=require" \
  -c "SELECT * FROM dr_failover_marker ORDER BY ts DESC LIMIT 1;"
# Should return a recent timestamp inserted by failover.py
```

---

## Manual Failover (if automation fails)

If `health_monitor.py` is not running or automation fails mid-way, execute manually:

```bash
cd /opt/dr-orchestrator/scripts
source .env

# Full failover
python failover.py --mode full

# App only (if DB is already promoted)
python failover.py --mode app-only

# DB only (if app traffic is already routed to Azure)
python failover.py --mode db-only
```

### Manual step-by-step (if the script itself fails)

**1. Scale AKS nodes**
```bash
az aks nodepool scale \
  --resource-group $AZURE_RESOURCE_GROUP \
  --cluster-name   $AZURE_AKS_CLUSTER \
  --name           app \
  --node-count     3
```

**2. Get AKS credentials and deploy**
```bash
az aks get-credentials --resource-group $AZURE_RESOURCE_GROUP --name $AZURE_AKS_CLUSTER
kubectl apply -f k8s/azure/ --recursive
kubectl rollout status deployment/api -n app --timeout=300s
```

**3. Promote PostgreSQL**
```bash
PGPASSWORD=$AZURE_PG_PASSWORD psql \
  "host=$AZURE_PG_FQDN dbname=appdb user=dbadmin sslmode=require" \
  -c "SELECT pglogical.drop_subscription('aws_subscription');"
PGPASSWORD=$AZURE_PG_PASSWORD psql \
  "host=$AZURE_PG_FQDN dbname=appdb user=dbadmin sslmode=require" \
  -c "SELECT pglogical.drop_node('replica_node');"
```

**4. Update Route53 DNS**
```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $ROUTE53_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.'$DOMAIN_NAME'",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{"Value": "'$AZURE_LB_IP'"}]
      }
    }]
  }'
```

---

## Verification Checklist

After failover (automated or manual):

- [ ] `dig api.<domain>` returns Azure LB IP
- [ ] `curl https://api.<domain>/healthz` returns HTTP 200
- [ ] Azure PostgreSQL accepts writes (insert test row)
- [ ] Grafana shows RTO metric populated
- [ ] SNS alert received: "Failover complete"
- [ ] No pglogical replication running (Azure DB is now standalone)
- [ ] Application logs show requests being served from Azure pods

---

## Escalation

| Scenario | Action |
|----------|--------|
| Automation fails, manual steps also fail | Page engineering lead; declare major incident |
| AKS nodes won't scale | Check Azure quota limits; open Azure support ticket |
| DNS not propagating | Reduce TTL to 30s; check Route53 change status |
| DB promotion fails | Check pglogical slot status; manually drop slot |
| RTO > 15 minutes | Declare SLA breach; file post-mortem |

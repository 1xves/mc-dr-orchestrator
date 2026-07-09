# Runbook: Manual Failback (Azure → AWS)

**Severity:** P2 (planned operation — AWS is already healthy)
**Estimated Duration:** 20–45 minutes
**Pre-requisite:** AWS primary is confirmed healthy BEFORE starting
**Owner:** On-call SRE + DB Admin

---

## Overview

Failback is always **manual** — it is never automated. This prevents a flapping scenario where the system bounces between clouds during intermittent failures. An engineer must confirm that AWS is stable before initiating.

---

## Pre-Flight Checklist (do NOT skip)

Run the readiness check script first:

```bash
cd /opt/dr-orchestrator/scripts
source .env
python failback.py --verify-only
```

Expected output:
```json
{
  "ready": true,
  "checks": {
    "primary_http": true,
    "rds_connectivity": true,
    "eks_reachable": true
  }
}
```

If any check is `false`, **do not proceed** until the underlying issue is resolved.

Also confirm manually:

- [ ] AWS incident is fully resolved and root cause identified
- [ ] AWS RDS is accepting connections and all tables are intact
- [ ] EKS nodes are Ready and application pods would start successfully
- [ ] VPN tunnels between AWS and Azure are UP (check Grafana)
- [ ] Engineering lead has approved the failback window

---

## Automated Failback

Once pre-flight passes, run:

```bash
# Dry run first — simulates all steps without making changes
python failback.py --execute --dry-run

# If dry run looks good, execute for real
python failback.py --execute
```

The script will print a JSON summary on completion.

---

## Manual Failback Steps (if script fails)

### Step 1 — Deploy application to EKS

```bash
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME
kubectl apply -f k8s/aws/ --recursive
kubectl rollout status deployment/api -n app --timeout=300s
kubectl get pods -n app
```

### Step 2 — Resync data from Azure → AWS (forward-catch up)

This step re-establishes pglogical in the **reverse** direction (Azure → AWS) to pick up any writes that occurred during the failover window:

```bash
# On AWS RDS: set it up as subscriber to Azure
PGPASSWORD=$RDS_PASSWORD psql "host=$RDS_ENDPOINT dbname=appdb user=$RDS_ADMIN sslmode=require" <<'EOF'
SELECT pglogical.create_node(
    node_name := 'aws_primary',
    dsn := 'host=RDS_ENDPOINT dbname=appdb user=dbadmin password=RDS_PASSWORD'
);

SELECT pglogical.create_subscription(
    subscription_name := 'azure_to_aws_sync',
    provider_dsn := 'host=AZURE_PG_FQDN dbname=appdb user=dbadmin password=AZURE_PG_PASSWORD sslmode=require',
    replication_sets := ARRAY['default'],
    synchronize_data := true
);
EOF
```

**Monitor replication lag** until it reaches 0:
```bash
PGPASSWORD=$RDS_PASSWORD psql "host=$RDS_ENDPOINT dbname=appdb user=$RDS_ADMIN sslmode=require" \
  -c "SELECT extract(epoch from (now() - pg_last_xact_replay_timestamp()))::int AS lag_s;"
# Wait until lag_s = 0
```

### Step 3 — Switch DNS back to AWS

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $ROUTE53_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.'$DOMAIN_NAME'",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "'$AWS_LB_IP'"}]
      }
    }]
  }'

# Wait for propagation
aws route53 wait resource-record-sets-changed --id <ChangeId>
```

### Step 4 — Scale AKS back to zero

```bash
az aks nodepool scale \
  --resource-group $AZURE_RESOURCE_GROUP \
  --cluster-name   $AZURE_AKS_CLUSTER \
  --name           app \
  --node-count     0
```

This returns Azure to zero-cost standby mode.

### Step 5 — Re-establish normal pglogical direction (AWS → Azure)

Remove the reverse sync and restore forward replication:

```bash
# On AWS RDS: drop the reverse subscription, restore forward publisher role
PGPASSWORD=$RDS_PASSWORD psql "host=$RDS_ENDPOINT dbname=appdb user=$RDS_ADMIN sslmode=require" <<'EOF'
SELECT pglogical.drop_subscription('azure_to_aws_sync');
SELECT pglogical.drop_node('aws_primary');

-- Restore publisher
SELECT pglogical.create_node(
    node_name := 'aws_primary',
    dsn := 'host=RDS_ENDPOINT dbname=appdb user=dbadmin password=RDS_PASSWORD'
);
SELECT pglogical.create_replication_set('default');
SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);
EOF

# On Azure PostgreSQL: re-subscribe to AWS
PGPASSWORD=$AZURE_PG_PASSWORD psql "host=$AZURE_PG_FQDN dbname=appdb user=$AZURE_PG_ADMIN sslmode=require" <<'EOF'
SELECT pglogical.create_node(
    node_name := 'replica_node',
    dsn := 'host=AZURE_PG_FQDN dbname=appdb user=dbadmin password=AZURE_PG_PASSWORD sslmode=require'
);

SELECT pglogical.create_subscription(
    subscription_name := 'aws_subscription',
    provider_dsn := 'host=RDS_ENDPOINT dbname=appdb user=dbadmin password=RDS_PASSWORD',
    replication_sets := ARRAY['default'],
    synchronize_data := true
);
EOF
```

---

## Verification Checklist

- [ ] `dig api.<domain>` returns AWS LB IP
- [ ] `curl https://api.<domain>/healthz` returns HTTP 200
- [ ] Application logs show requests served from EKS (not AKS)
- [ ] Azure AKS node count = 0 in Grafana
- [ ] pglogical replication lag < 10s and falling in Grafana
- [ ] RDS replication lag metric is 0
- [ ] Failback completion notification received via SNS/Slack

---

## Post-Failback Actions

1. **Schedule post-mortem** within 48 hours of the original failover
2. **Update DR test date** — run Chaos Mesh test within 2 weeks to re-validate
3. **Review RTO/RPO metrics** in Grafana and compare to targets
4. **Check cost** — Azure VMs should now be at zero; verify in Azure Cost Management
5. **Update runbook** if any step was unclear or had to be improvised

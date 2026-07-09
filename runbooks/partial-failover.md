# Runbook: Partial Failover

**Purpose:** Move only part of the stack to Azure — either the database or the application tier — without a full cut-over.

**When to use:**
- **DB-only:** AWS RDS is degraded or needs maintenance, but EKS and application are fine
- **App-only:** EKS nodes are unavailable (AZ outage, node group failure) but RDS is healthy

---

## Option A: Database-Only Failover

**Scenario:** RDS Primary is down or degraded. Application pods on EKS are healthy.

### Step 1 — Promote Azure PostgreSQL

```bash
cd /opt/dr-orchestrator/scripts && source .env
python failover.py --mode db-only
```

Or manually:

```bash
# Sever pglogical replication and open Azure DB for writes
PGPASSWORD=$AZURE_PG_PASSWORD psql \
  "host=$AZURE_PG_FQDN dbname=appdb user=dbadmin sslmode=require" \
  -c "SELECT pglogical.drop_subscription('aws_subscription');
      SELECT pglogical.drop_node('replica_node');"
```

### Step 2 — Update application DB connection string

Update the Kubernetes secret on EKS to point to Azure PostgreSQL:

```bash
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME

kubectl create secret generic db-credentials -n app \
  --from-literal=host=$AZURE_PG_FQDN \
  --from-literal=password=$AZURE_PG_PASSWORD \
  --from-literal=user=dbadmin \
  --from-literal=dbname=appdb \
  --dry-run=client -o yaml | kubectl apply -f -

# Rolling restart to pick up new DB host
kubectl rollout restart deployment/api -n app
kubectl rollout status deployment/api -n app --timeout=300s
```

### Step 3 — Verify

```bash
# Confirm EKS pods connect to Azure PG
kubectl logs -n app -l app=api --tail=50 | grep "Connected to"

# Test a DB write via the API
curl -sf -X POST https://api.<domain>/api/test-write
```

### Failback from DB-only failover

```bash
# Once RDS is restored:
# 1. Re-establish pglogical from Azure → AWS (catch-up sync)
# 2. Update k8s secret back to RDS endpoint
# 3. Rolling restart deployment
kubectl create secret generic db-credentials -n app \
  --from-literal=host=$RDS_ENDPOINT \
  --from-literal=password=$RDS_PASSWORD \
  --from-literal=user=dbadmin \
  --from-literal=dbname=appdb \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/api -n app
```

---

## Option B: Application-Only Failover

**Scenario:** EKS nodes are unavailable (AZ failure, node group issue). RDS is healthy.

### Step 1 — Scale AKS and deploy

```bash
python failover.py --mode app-only
```

Or manually:

```bash
# Scale AKS
az aks nodepool scale \
  --resource-group $AZURE_RESOURCE_GROUP \
  --cluster-name   $AZURE_AKS_CLUSTER \
  --name           app \
  --node-count     3

# Get credentials and deploy
az aks get-credentials --resource-group $AZURE_RESOURCE_GROUP --name $AZURE_AKS_CLUSTER

# Update DB secret to point to AWS RDS (AKS connects back to RDS via VPN)
kubectl create secret generic db-credentials -n app \
  --from-literal=host=$RDS_ENDPOINT \
  --from-literal=password=$RDS_PASSWORD \
  --from-literal=user=dbadmin \
  --from-literal=dbname=appdb \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/azure/ --recursive
kubectl rollout status deployment/api -n app --timeout=300s
```

### Step 2 — Switch DNS to Azure LB

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

### Step 3 — Verify cross-cloud DB connectivity

```bash
# Confirm AKS pods can reach AWS RDS via VPN
kubectl exec -n app deployment/api -- \
  sh -c "nc -zv $RDS_ENDPOINT 5432 && echo OK"
```

### Failback from app-only failover

```bash
# Once EKS is restored:
# 1. Scale EKS nodes back to desired count (if needed)
# 2. Redeploy to EKS
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME
kubectl apply -f k8s/aws/ --recursive
kubectl rollout status deployment/api -n app

# 3. Switch DNS back to AWS
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

# 4. Scale AKS back to zero
az aks nodepool scale \
  --resource-group $AZURE_RESOURCE_GROUP \
  --cluster-name   $AZURE_AKS_CLUSTER \
  --name app --node-count 0
```

---

## Decision Matrix

| Symptom | Recommended Action |
|---------|-------------------|
| RDS down, EKS OK | DB-only failover |
| EKS down, RDS OK | App-only failover |
| Both down | Full failover (see automated-failover.md) |
| Degraded performance only | Consider read replica scaling before failover |
| Single AZ outage | Check if multi-AZ RDS auto-promoted; may not need DR |

---

## Notes

- VPN tunnels must be UP for app-only failover (AKS → RDS cross-cloud traffic)
- DB-only failover incurs write split risk if any EKS pods are still using the old RDS endpoint — ensure the secret is updated atomically with a rolling restart
- Always record the approximate LSN at the time of failover to calculate RPO accurately

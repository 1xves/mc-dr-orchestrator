# Runbook — Failover (GKE Primary → AKS Standby)

**Trigger:** GKE primary is unreachable or degraded and service must be restored on Azure AKS.

---

## Pre-checks (2 min)

1. Confirm the alert is not a transient blip:
   ```bash
   curl -s https://api.yourdomain.com/healthz
   kubectl get pods -n default   # GKE context
   ```

2. Confirm AKS standby cluster exists and is reachable:
   ```bash
   az aks show --name mc-dr-aks --resource-group mc-dr-standby-rg --query provisioningState
   ```

3. Retrieve the AKS LoadBalancer IP (needed as argument):
   ```bash
   # After AKS nodes are up, get the external IP:
   kubectl get svc -n default   # AKS context
   # Note the EXTERNAL-IP column
   ```
   If nodes are at 0, the LB IP was assigned at last apply; check `terraform output` or Azure portal.

---

## Execution

Run with `--dry-run` first to confirm parameters:

```bash
python scripts/failover.py \
  --gcp-project YOUR_GCP_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks \
  --aks-ingress-ip AZURE_LB_IP \
  --dry-run
```

If dry-run output looks correct, remove `--dry-run` and execute.

**Expected sequence:**
1. Three consecutive health-check failures confirmed → proceed
2. AKS node pool scaled to 2 nodes
3. Wait for AKS cluster `Succeeded` state (up to 10 min)
4. Cloud DNS A record updated: `api.yourdomain.com → AZURE_LB_IP` (TTL 60s)
5. Pub/Sub event published to `mc-dr-dr-alerts`

---

## Post-failover verification

```bash
# DNS propagation check (allow up to 60s for TTL)
dig api.yourdomain.com +short

# Confirm AKS serving traffic
curl -s https://api.yourdomain.com/healthz

# Check Pub/Sub event was received
gcloud pubsub subscriptions pull mc-dr-alerts-sub --auto-ack --limit=5
```

---

## Estimated RTO

| Step | Time |
|---|---|
| AKS node scale-up | 3-5 min |
| Postgres pod start | 30-60s |
| DNS propagation | up to 60s (TTL 60) |
| **Total** | **~5-7 min** |

---

## Rollback

If AKS cannot serve traffic after failover:
- Investigate AKS pods: `kubectl get pods -n database -n default`
- If GKE primary recovers before AKS stabilizes, run failback immediately
- Do not leave DNS pointing at a non-serving endpoint for more than 15 min

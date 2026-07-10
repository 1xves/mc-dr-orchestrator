# Runbook — Cost Management

This project has two billing incidents in its history ($245 GCP, $140 AWS) that drove the current defensive architecture. This runbook documents what to watch and how to respond.

---

## Cost baseline (both clusters idling, nodes=0)

| Resource | Monthly cost |
|---|---|
| GKE Postgres PVC (10Gi, standard-rwo) | ~$0.40 |
| AKS Postgres PVC (10Gi, managed-csi) | ~$0.44 |
| GCS Terraform state bucket | ~$0.01 |
| Cloud DNS zone | ~$0.20 |
| **Total idle** | **~$1.05/month** |

`terraform destroy` reaches true $0 (no reserved capacity, no managed services).

---

## Billing budget alert

A GCP billing budget is configured at $50/month with alerts at 50%, 90%, and 100%. To enable it, set `gcp_billing_account_id` in `terraform.tfvars`.

To find your billing account ID:
```bash
gcloud billing accounts list
```

---

## High-cost resources — gated by default

These resources are off by default and must be explicitly enabled:

### Cross-cloud VPN (`enable_vpn = true`)
- GCP HA VPN: ~$73/month
- Azure VPN Gateway (VpnGw1): ~$140/month
- Egress/tunnel: variable
- **Total: ~$213-280/month**
- Use case: production-grade encrypted backbone; not needed for portfolio demo

### Cloud NAT (`enable_nat = true`)
- GCP Cloud NAT: ~$32/month
- Use case: outbound internet from private GKE nodes; not required when nodes are at 0

### GKE regional cluster
- Zonal cluster (current): $0 management fee (first per billing account)
- Regional cluster: $0.10/hr = ~$72/month
- The current config uses `location = var.gcp_zone`, keeping it zonal

---

## Emergency cost reduction

If you see unexpected charges:

1. **Immediately scale to 0:**
   ```bash
   ./scripts/scale.sh down
   ```

2. **Verify VPN is off (this was the $140 AWS incident pattern):**
   ```bash
   terraform show | grep enable_vpn
   # Should show: enable_vpn = false
   ```

3. **Check for orphaned resources:**
   ```bash
   # GCP — list all running VMs
   gcloud compute instances list

   # Azure — list all running VMs
   az vm list --output table

   # Terraform state should account for everything
   terraform state list | grep -E "(vpn|nat|sql)"
   ```

4. **Nuclear option — destroy everything:**
   ```bash
   cd terraform
   terraform destroy
   ```
   This removes all Terraform-managed resources. PVCs are destroyed, data is lost. Use only in emergencies.

---

## Prior incidents and lessons

| Date | Amount | Root cause | Fix applied |
|---|---|---|---|
| 2024 | $245 GCP | GCP Feature Store node pool left running; Cloud NAT provisioned | Cloud NAT gated behind `enable_nat=false`; node pool count defaults to 0 |
| 2024 | $140 AWS | AWS VPN Gateway left provisioned | AWS account closed; VPN gated behind `enable_vpn=false` on remaining providers |

---

## Monthly checklist

- [ ] Check GCP billing console for unexpected line items
- [ ] Verify GKE + AKS node counts are 0 (if project is idle)
- [ ] Confirm `enable_vpn = false` and `enable_nat = false` in current tfvars
- [ ] Review billing budget alert subscription is active

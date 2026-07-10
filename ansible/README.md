# Ansible: API-driven Postgres deployment

Deploys the Postgres 15 StatefulSet to both clusters (GKE primary in GCP,
AKS standby in Azure) from one playbook and one inventory. This replaces the
old Terraform `null_resource` local-exec kubectl pattern, which had no state,
no drift detection, and broke plan purity.

There is no SSH here. Each inventory host is a Kubernetes API target selected
by kubeconfig context (`ansible_connection: local` + `kubernetes.core`), which
is Ansible's API-driven application deployment mode rather than SSH config
management.

## Layout

```
ansible/
├── ansible.cfg
├── requirements.yml          # kubernetes.core collection
├── inventory/hosts.yml       # gke-primary + aks-standby, one context each
├── group_vars/all.yml        # shared Postgres settings; password from env
├── templates/                # single Jinja2 source for both clouds
│   ├── namespace.yaml.j2
│   ├── statefulset.yaml.j2   # role + storageClassName vary per cluster
│   └── services.yaml.j2
├── deploy_postgres.yml       # the deployment playbook
└── render_manifests.yml      # render templates to build/ for CI validation
```

## Prerequisites

- `ansible-core` >= 2.16 and the `kubernetes` Python client on the controller
  (both in the repo root `requirements.txt`)
- `ansible-galaxy collection install -r requirements.yml`
- kubeconfig contexts for both clusters (fetch commands are documented in
  `inventory/hosts.yml`)

## Usage

```bash
cd ansible
export DB_MASTER_PASSWORD=<password>   # never committed, asserted non-empty

ansible-playbook deploy_postgres.yml                     # both clusters
ansible-playbook deploy_postgres.yml --limit gke-primary # one cluster
ansible-playbook deploy_postgres.yml --check --diff      # dry run / drift check
```

Cold-standby notes:

- The AKS cluster is normally stopped. Deploy right after `terraform apply`
  while it is running, or `az aks start` first. The playbook fails fast with
  guidance if a cluster API is unreachable.
- If a node pool is scaled to zero, pods cannot schedule; skip the readiness
  wait with `-e postgres_wait_for_ready=false`.

## What is intentionally NOT here

`failover.py` and `failback.py` stay in Python. They orchestrate cross-cloud
control-plane actions (node scaling, DNS repoint, health verification) and
work; porting them to YAML would duplicate working code for no operational
gain.

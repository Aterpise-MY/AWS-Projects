# Ansible — Host Layer and Day-2 Operations

Ansible on this platform operates at the **host layer** and for **day-2
operational tasks**. It does not deploy the application — Kubernetes does, driven
by Helm from an image in ECR. Every playbook restates this boundary in a comment
block at the top; it is the single most important thing to understand about this
directory.

## Table of Contents

1. [Layer boundary](#layer-boundary)
2. [What lives here](#what-lives-here)
3. [Roles](#roles)
4. [Playbooks](#playbooks)
5. [Access model — no SSH, ever](#access-model--no-ssh-ever)
6. [CIS hardening scope](#cis-hardening-scope)
7. [Kernel tuning](#kernel-tuning)
8. [Idempotency](#idempotency)
9. [Running against live hosts](#running-against-live-hosts)
10. [Prerequisites](#prerequisites)

---

## Layer boundary

```
┌───────────────────────────────────────────────────────────────────┐
│  APPLICATION   Laravel: web, worker, scheduler, migrate            │
│                Owner: Helm + Kubernetes. Source: OCI image in ECR. │
│                Ansible NEVER touches this layer.                   │
├───────────────────────────────────────────────────────────────────┤
│  ORCHESTRATION Scheduling, Services, secrets delivery, scaling     │
│                Owner: EKS control plane.                           │
├───────────────────────────────────────────────────────────────────┤
│  HOST          Packages, kernel params, modules, systemd, agents,  │
│                containerd config, filesystem permissions           │
│                Owner: ANSIBLE (this directory).                    │
├───────────────────────────────────────────────────────────────────┤
│  IMAGE         Base AMI selection, snapshot, registration          │
│                Owner: Packer (../packer). Invokes node-hardening.  │
└───────────────────────────────────────────────────────────────────┘
```

Ansible owns exactly one layer. Two consumers drive it: Packer at bake time, and
an operator over SSM for drift correction and day-2 tasks.

---

## What lives here

```
ansible/
├── ansible.cfg                       yaml stdout, SSM-friendly, dynamic inventory
├── requirements.yml                  Galaxy collections (amazon.aws, community.aws, ...)
├── inventory/
│   └── aws_ec2.yml                   aws_ec2 dynamic inventory, keyed on Component + Environment
├── files/                            committed artefacts (schema baseline lands here)
├── playbooks/
│   ├── node-hardening.yml            invoked by Packer; composed of the four roles
│   ├── bastion.yml                   operator jump box: kubectl, helm, awscli, mysql
│   └── db-maintenance.yml            snapshot / schema diff / credential rotation
└── roles/
    ├── base-packages/                ops tooling, time sync, journald + ulimit caps
    ├── cis-hardening/                the EKS-safe subset of CIS AL2023
    ├── monitoring-agents/            CloudWatch agent + SSM agent
    └── containerd-tuning/            runtime + CNI module + image GC tuning
```

---

## Roles

| Role | Owns | Notable decisions |
|---|---|---|
| `base-packages` | Operational tooling, chrony against the Amazon Time Sync Service, journald disk cap, PAM + systemd ulimits | In-place patching is disabled — nodes are replaced, not patched, to preserve the AMI provenance tags |
| `cis-hardening` | The subset of CIS AL2023 that does not break EKS | Explicit skipped-controls block; security sysctls plus the EKS tuning sysctls |
| `monitoring-agents` | CloudWatch agent (host metrics + host logs) and SSM agent | Container logs are Fluent Bit's job, not this role's; agent state is purged at bake time |
| `containerd-tuning` | containerd config drop-in, required CNI modules, image GC thresholds, OOM protection | Never edits the nodeadm-generated `config.toml`; asserts the drop-in is actually imported |

---

## Playbooks

| Playbook | Trigger | What it does |
|---|---|---|
| `node-hardening.yml` | Packer, twice per bake | Applies the four roles. Second pass must report `changed=0`. |
| `bastion.yml` | On demand | Installs `kubectl`, `helm`, `awscli` v2, the mysql client, and the SSM plugin on an operator jump box. Masks sshd. |
| `db-maintenance.yml` | On demand, tag-selected | `--tags snapshot` (safe), `--tags schema` (read-only drift diff), `--tags rotate` (rotate the DB password and roll dependent Deployments; requires `-e confirm_rotation=true`) |

---

## Access model — no SSH, ever

There is no SSH key on any host in this platform, and no security group anywhere
has a port 22 ingress rule. Every host is reached through **AWS Systems Manager
Session Manager**:

```bash
aws ssm start-session --target <instance-id> --region ap-southeast-1
```

Why this is the model, not just a preference:

- **No key to lose or rotate.** Access is an IAM decision, revoked by removing a
  policy, not by hunting down a key someone copied three years ago.
- **Every session is attributable and recorded.** Session Manager authenticates
  with IAM and logs the principal to CloudTrail. A shared SSH key is
  attributable to a key, not a person.
- **No listening port.** Nothing to scan, brute-force, or hit with a pre-auth
  CVE. The agent is outbound-only.

`bastion.yml` enforces this: it asserts no `authorized_keys` file exists, and
masks `sshd`. The day-2 inventory connects over the `community.aws.aws_ssm`
connection plugin. Packer is the one exception — it connects over SSH to its own
throwaway build instance because that instance is not SSM-registered — and the
build strips any key material before the AMI is sealed.

---

## CIS hardening scope

The `cis-hardening` role applies the subset of the CIS Amazon Linux 2023
Benchmark that an EKS worker node survives. A stock CIS profile applied whole
produces a node that passes the scan and cannot run a pod. The controls below
are **deliberately skipped**, each because it breaks something specific — the
full rationale is in `roles/cis-hardening/tasks/main.yml`:

| CIS control | Why it is skipped |
|---|---|
| 3.1.1 / 3.3.1 IP forwarding disabled | Breaks all pod networking; the VPC CNI and kube-proxy require forwarding |
| 1.1.1.x overlay/squashfs blacklist | `overlay` is containerd's snapshotter; blacklisting it stops every pod |
| 3.5.x host firewall default-deny | Fights kube-proxy and the CNI for ownership of the nftables ruleset |
| 3.3.x disable IPv6 | Removes `::1`, which several Go runtimes bind for loopback health checks |
| 1.1.2.x separate partitions | The kubelet's disk-pressure logic reads one filesystem; splitting it misleads eviction |
| 4.1.1.4 immutable audit rules (`-e 2`) | Needs a reboot to change; blocks incident-time rule edits on a node that is replaced, not rebooted |
| 6.1.x world-writable remediation | The automated fix walks every containerd image layer; slow, non-idempotent, can corrupt layers |

What **is** applied: filesystem/protocol module blacklists (minus the ones above),
the section-3 network security sysctls, ASLR / core-dump / kptr restrictions,
account and password policy, sshd hardening, and a host-scoped auditd ruleset.

---

## Kernel tuning

Beyond CIS, `cis-hardening` raises the connection and watch limits that a busy
Kubernetes node exhausts before it runs out of CPU or memory. Each of these
fails in a way that looks like an application bug:

| Parameter | Value | Failure it prevents |
|---|---|---|
| `net.core.somaxconn` | `65535` | Connection resets under burst when the accept queue overflows |
| `net.ipv4.ip_local_port_range` | `10240 65535` | `cannot assign requested address` from kube-proxy SNAT port exhaustion |
| `net.netfilter.nf_conntrack_max` | `524288` | `nf_conntrack: table full, dropping packet` — random silent drops |
| `fs.inotify.max_user_instances` | `8192` | New pods failing to start after ~20 pods exhaust the default of 128 |
| `fs.inotify.max_user_watches` | `524288` | Log shippers and projected volumes running out of watches |

---

## Idempotency

Idempotency is a hard requirement, not an aspiration. `node-hardening.yml` is
run twice by Packer and the second pass must report `changed=0`. The rules the
roles follow:

- `ansible.builtin.*` FQCNs throughout.
- No bare `shell`/`command` without a `creates:` or `changed_when:` guard. Where
  a non-idempotent command is unavoidable (`useradd -D`, `sysctl --system`), the
  current state is read first and the command runs only on a real mismatch, or
  the task is a `notify`-only handler where "changed" is accurate by
  construction.
- Config is written by templates with fixed content — no embedded timestamps —
  so a re-render is byte-identical.

---

## Running against live hosts

```bash
cd "Laravel Ticketing System on EKS/ansible"

# Install collections
ansible-galaxy collection install -r requirements.yml

# The aws_ssm connection plugin needs an S3 bucket for file transfer
export ANSIBLE_AWS_SSM_BUCKET_NAME=<an-existing-bucket>

# Preview the dynamic inventory
ansible-inventory -i inventory/aws_ec2.yml --graph

# Drift-correct the app node group
ansible-playbook playbooks/node-hardening.yml --limit component_compute

# Provision a bastion
ansible-playbook playbooks/bastion.yml

# Day-2: snapshot, then check for schema drift
ansible-playbook playbooks/db-maintenance.yml --tags snapshot
ansible-playbook playbooks/db-maintenance.yml --tags schema
```

> `ansible` is not installed on the authoring workstation for this project, so
> these playbooks have been validated for YAML/structure only, not executed. See
> the verification note in the build report.

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| `ansible-core` | 2.16 | FQCN modules, `meta: flush_handlers` |
| `python3` | 3.9 | Control node and target interpreter |
| `boto3` / `botocore` | current | Required by `amazon.aws` and the aws_ec2 inventory |
| Collections | see `requirements.yml` | `amazon.aws`, `community.aws`, `ansible.posix`, `community.general`, `community.mysql`, `kubernetes.core` |
| AWS credentials | — | Read-only for inventory; snapshot/rotate need RDS + Secrets Manager write |

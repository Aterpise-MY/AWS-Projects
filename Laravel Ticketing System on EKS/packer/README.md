# Packer — EKS Node AMI Baking

This directory bakes a hardened Amazon Linux 2023 arm64 AMI for the EKS worker
nodes of the ticketing platform. The image is derived from the official
AWS EKS-optimized node AMI, layered with an Ansible-managed host baseline, and
published as an AMI ID that Terraform consumes as `modules/eks` input
`node_ami_id`.

## Table of Contents

1. [Why does a Kubernetes platform still need Packer?](#why-does-a-kubernetes-platform-still-need-packer)
2. [Where Packer's role ends](#where-packers-role-ends)
3. [Build pipeline](#build-pipeline)
4. [Directory contents](#directory-contents)
5. [Source AMI selection](#source-ami-selection)
6. [Input variables](#input-variables)
7. [AMI tags](#ami-tags)
8. [Running a build](#running-a-build)
9. [Consuming the manifest from Terraform](#consuming-the-manifest-from-terraform)
10. [AMI garbage collection](#ami-garbage-collection)
11. [Frequently asked questions](#frequently-asked-questions)

---

## Why does a Kubernetes platform still need Packer?

The honest starting position is that containers took most of Packer's job away.
Ten years ago the AMI *was* the deployment unit: application code, runtime,
dependencies and OS all shipped together and a release meant a new image. On
this platform the release unit is an OCI image in ECR tagged with a git SHA, and
the node is a fungible slab of CPU and memory. If the argument for Packer were
"we need to bake the app in", there would be no argument.

Two things survive that shift.

### 1. Node boot time

Nodes on this platform are Spot `t4g.medium` instances in an autoscaling group
that Cluster Autoscaler drives between 2 and 4. Scale-out latency is the time
from "pod is Pending" to "pod is Running", and the node's own boot is the
dominant term in that sum:

```
┌──────────────────────────────────────────────────────────────────┐
│  Pod Pending                                                     │
│      │                                                           │
│      ▼                                                           │
│  Cluster Autoscaler decides          ~10-30s                     │
│      │                                                           │
│      ▼                                                           │
│  EC2 provisions instance             ~20-40s                     │
│      │                                                           │
│      ▼                                                           │
│  ┌─────────────────────────────────────────────────────┐         │
│  │ Node boot                                           │         │
│  │                                                     │         │
│  │  stock AMI + userdata:                              │         │
│  │    dnf update, install agents, apply sysctl,        │         │
│  │    write containerd config, restart containerd      │         │
│  │                              60-180s  ◄── variable  │         │
│  │                                                     │         │
│  │  baked AMI:                                         │         │
│  │    nodeadm init, join cluster                       │         │
│  │                              15-25s   ◄── flat      │         │
│  └─────────────────────────────────────────────────────┘         │
│      │                                                           │
│      ▼                                                           │
│  Image pull + pod start               ~10-30s                    │
│      │                                                           │
│      ▼                                                           │
│  Pod Running                                                     │
└──────────────────────────────────────────────────────────────────┘
```

The number that matters is not the average, it is the variance. A userdata
script that runs `dnf install` at boot has a runtime that depends on a package
mirror it does not control. On a Spot fleet where nodes are reclaimed with two
minutes of notice, a replacement node whose boot time is a distribution rather
than a constant is an availability problem, not a performance nicety. Baking
moves that work to build time, where a slow mirror costs a CI minute instead of
a user-facing latency spike.

> This is a real but bounded win. It buys roughly one to two minutes per node
> launch on this stack. If the platform ran a fixed-size node group that scaled
> once a quarter, the win would be close to zero and the pipeline would not pay
> for itself.

### 2. Compliance baseline with a provenance trail

The second argument is the one that actually survives scrutiny in a regulated
environment, and it is about evidence rather than speed.

A hardened host baseline has to exist somewhere. The options are: userdata (runs
after the node has already joined and started accepting pods, so there is a
window where an unhardened node is schedulable), a DaemonSet with host mounts
and elevated privileges (a privileged container that rewrites `/etc/sysctl.d`
and `/etc/containerd` is a worse security posture than the thing it is fixing),
or a baked image (the baseline is a precondition of the node existing at all).

Baking is the only one of the three where "was this node hardened?" has a
yes/no answer rather than a timing-dependent one.

It also produces an artifact you can point an auditor at. Every AMI this
pipeline emits carries:

| Tag | Answers the question |
|---|---|
| `SourceAMI` / `SourceAMIName` | Which AWS-published image is this derived from? |
| `GitSHA` | Which commit of the hardening roles produced it? |
| `BuildTimestamp` | When was the baseline applied? |
| `KubernetesVersion` | Which control-plane version is it matched to? |

When a CVE lands against a package in the base image, the response is a tag
query, not an archaeology exercise across running instances. That trail is the
thing you cannot reconstruct after the fact if the baseline was applied by a
boot script.

---

## Where Packer's role ends

Being specific about what this pipeline deliberately does **not** do is more
useful than a longer list of what it does.

| Concern | Owner | Not Packer because |
|---|---|---|
| Application code, PHP runtime, Composer deps | Docker image in ECR | The release unit is an OCI image tagged with a git SHA. Rebaking an AMI per deploy would be absurd. |
| Application config and secrets | External Secrets + Helm values | Config that changes per environment must not be frozen into an image. |
| Kubernetes version upgrades | EKS managed node group + a new bake | Packer follows the control plane; it does not drive it. |
| Autoscaling, scheduling, placement | Cluster Autoscaler, kube-scheduler | Nothing image-level. |
| Day-2 patching of a running node | Node replacement, not in-place patching | Nodes are cattle. A patched-in-place node is a snowflake with no provenance tag. |
| Runtime policy enforcement | Kubernetes NetworkPolicy, Pod Security Standards | Enforced by the control plane, per-workload, and changeable without a rebuild. |

That table is most of the surface area of the platform. Packer owns one layer
of one of those rows.

### The uncomfortable part

There is a defensible version of this platform with no Packer at all: use the
stock EKS-optimized AMI unmodified, put the sysctl tuning into a managed node
group launch template's userdata, install the CloudWatch agent as a DaemonSet,
and accept the extra boot time. It would be less code, fewer moving parts, and
one less pipeline to keep green. For a two-to-four node dev cluster that is
arguably the right call.

The bake earns its place when at least one of these is true:

- Node churn is high enough that boot-time variance is a live availability
  concern (Spot fleets, bursty autoscaling, frequent rollouts).
- An auditor needs a per-node answer to "what baseline was applied and when",
  with an artifact rather than a log grep.
- The baseline is large enough that running it at boot pushes node readiness
  past the scheduler's patience.

On this platform the first two hold, so the pipeline stays. It should be deleted
the moment they stop holding. A build pipeline that exists because it was
impressive to write is a liability.

> Packer here is roughly 200 lines of HCL and a handful of Ansible roles. That
> is deliberately the whole of it. If this directory ever grows an application
> layer, the boundary has been violated and the fix is to move that layer into
> the container image.

---

## Build pipeline

```
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│   AWS EKS-optimized AL2023 arm64 AMI (owner 602401143452)          │
│   amazon-eks-node-al2023-arm64-standard-1.36-*                     │
│                              │                                     │
│                              ▼                                     │
│   ┌────────────────────────────────────────────────┐               │
│   │  Packer  amazon-ebs  (t4g.medium, ap-se-1)     │               │
│   │                                                │               │
│   │   shell      ── cloud-init --wait              │               │
│   │       │                                        │               │
│   │       ▼                                        │               │
│   │   ansible    ── ansible/playbooks/             │               │
│   │       │         node-hardening.yml             │               │
│   │       │         roles: base-packages           │               │
│   │       │                cis-hardening           │               │
│   │       │                monitoring-agents       │               │
│   │       │                containerd-tuning       │               │
│   │       ▼                                        │               │
│   │   ansible    ── second pass, expect changed=0  │               │
│   │       │                                        │               │
│   │       ▼                                        │               │
│   │   shell      ── strip build artefacts          │               │
│   └────────────────────────────────────────────────┘               │
│                              │                                     │
│                              ▼                                     │
│   AMI  ticketing-dev-eks-node-1.36-arm64-<timestamp>               │
│         + tagged EBS snapshot                                      │
│                              │                                     │
│                              ▼                                     │
│   packer/manifest.json  ──►  terraform  modules/eks.node_ami_id    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

Traffic flow: Packer orchestrates the lifecycle (launch, provision, snapshot,
register, tag, terminate). Ansible does every line of actual host configuration,
which is what makes the same baseline re-runnable against a live node for drift
correction rather than being a one-shot bake script.

---

## Directory contents

```
packer/
├── eks-node.pkr.hcl        Build definition: source AMI filter, provisioners, tags, manifest
├── cleanup-old-amis.py     AMI + snapshot garbage collector (dry-run by default)
├── manifest.json           Build output, git-ignored. Terraform reads node_ami_id from here.
└── README.md               This file
```

---

## Source AMI selection

The build filters on the official AWS-published family rather than pinning an
AMI ID, so a rebuild picks up the latest patched base automatically:

| Field | Value |
|---|---|
| Owner | `602401143452` (Amazon EKS AMI account) |
| Name pattern | `amazon-eks-node-al2023-arm64-standard-1.36-*` |
| Architecture | `arm64` |
| Root device | `ebs`, `hvm` |
| Selection | `most_recent = true` |

Verified live in `ap-southeast-1` on 2026-07-24:

```
amazon-eks-node-al2023-arm64-standard-1.36-v20260625   ami-04117a932fe8152dc
amazon-eks-node-al2023-arm64-standard-1.36-v20260618   ami-0d37e3ef42f27ea5d
amazon-eks-node-al2023-arm64-standard-1.36-v20260529   ami-0f67744293f313b4f
amazon-eks-node-al2023-arm64-standard-1.36-v20260527   ami-0d2400efbaa750c67
amazon-eks-node-al2023-arm64-standard-1.36-v20260520   ami-073fa459a2c6870b0
```

> `most_recent = true` means two builds a week apart can land on different base
> images. That is the intent — the base image is where OS CVE fixes arrive — but
> it also means the AMI is not a pure function of the git SHA. The `SourceAMI`
> tag records which base was used so a build is still reproducible after the
> fact by pinning that ID.

The build is arm64 only. Every instance type in the stack is Graviton
(`t4g.small` system nodes, `t4g.medium` app nodes), so an amd64 artifact would
be built, stored, and billed without ever being launched.

---

## Input variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | `string` | `ap-southeast-1` | Build region. AMIs are regional; must match the cluster. |
| `kubernetes_version` | `string` | `1.36` | Selects the matching official node AMI family. |
| `build_instance_type` | `string` | `t4g.medium` | Graviton build instance; must be arm64. |
| `name_prefix` | `string` | `ticketing-dev` | Name prefix aligned with the Terraform stack. |
| `git_sha` | `string` | `unknown` | Full 40-char commit SHA; CI passes this with `-var`. |
| `encrypt_boot` | `bool` | `true` | Encrypt the root snapshot with the account default EBS KMS key. |
| `ami_users` | `list(string)` | `[]` | Extra account IDs allowed to launch the AMI. |

---

## AMI tags

| Tag | Value | Purpose |
|---|---|---|
| `Name` | `ticketing-dev-eks-node-1.36-arm64` | Console readability |
| `Project` | `ticketing` | Cost allocation, and the key `cleanup-old-amis.py` filters on |
| `Environment` | `dev` | Cost allocation |
| `ManagedBy` | `packer` | Distinguishes from `terraform`-managed resources |
| `Component` | `compute` | Matches the `modules/eks` component value |
| `AutoDelete` | `true` | Marks the resource as safe for automated teardown |
| `Repository` | `github.com/brendonang/ticketing-platform` | Provenance |
| `SourceAMI` | e.g. `ami-04117a932fe8152dc` | Which AWS base image this derives from |
| `SourceAMIName` | e.g. `amazon-eks-node-al2023-arm64-standard-1.36-v20260625` | Human-readable base |
| `GitSHA` | 40-char commit SHA | Which version of the roles produced it |
| `BuildTimestamp` | ISO-8601 UTC | When the baseline was applied |
| `KubernetesVersion` | `1.36` | Control-plane version this node matches |
| `Architecture` | `arm64` | Guards against a wrong-arch launch template |

The same `Project` / `Environment` / `ManagedBy` / `Component` / `AutoDelete` /
`GitSHA` / `BuildTimestamp` set is applied to the backing EBS snapshot. This is
what lets the garbage collector find orphaned snapshots after someone
deregisters an AMI by hand in the console.

---

## Running a build

```bash
cd "Laravel Ticketing System on EKS/packer"

# 1. Install plugins declared in the required_plugins block
packer init eks-node.pkr.hcl

# 2. Format and validate
packer fmt   -check eks-node.pkr.hcl
packer validate -var "git_sha=$(git rev-parse HEAD)" eks-node.pkr.hcl

# 3. Build (roughly 8-12 minutes end to end)
packer build \
  -var "git_sha=$(git rev-parse HEAD)" \
  -var "region=ap-southeast-1" \
  eks-node.pkr.hcl

# 4. Read the resulting AMI ID
jq -r '.builds[-1].artifact_id | split(":")[1]' manifest.json
```

Requires `packer >= 1.11`, `ansible-core >= 2.16`, and AWS credentials with
permission to run an EC2 instance, create and tag AMIs and snapshots, and manage
the temporary key pair and security group Packer creates.

> `packer` and `ansible` are not installed on the authoring workstation for this
> project, so the HCL above has not been run through `packer validate`. It has
> been reviewed by eye for block structure. Run steps 1-2 before the first real
> build.

---

## Consuming the manifest from Terraform

The `manifest` post-processor writes `packer/manifest.json`. The last build's
`artifact_id` is of the form `<region>:<ami-id>`:

```bash
AMI_ID=$(jq -r '.builds[-1].artifact_id | split(":")[1]' packer/manifest.json)

terraform -chdir=terraform/dev apply -var "node_ami_id=${AMI_ID}"
```

`modules/eks` declares `node_ami_id` with a `null` default, so the cluster can
be stood up on the stock EKS-optimized AMI before the first bake exists and
switched to the custom image later without a code change.

> `manifest.json` is a build artifact and is git-ignored. CI passes the AMI ID
> forward as a job output rather than committing it, so Terraform state is the
> only place the currently-deployed AMI ID lives.

---

## AMI garbage collection

Deregistering an AMI does not delete the EBS snapshot behind it. A pipeline that
bakes on every merge and never sweeps leaves a multi-GiB snapshot billed every
month, indefinitely, and those snapshots are invisible in the AMI console view
once the registration is gone.

`cleanup-old-amis.py` closes that loop.

```bash
# Report only — this is the default, nothing is mutated
./cleanup-old-amis.py --region ap-southeast-1

# Include orphaned snapshots in the report
./cleanup-old-amis.py --include-orphan-snapshots

# Actually delete
./cleanup-old-amis.py --no-dry-run --include-orphan-snapshots
```

| Flag | Default | Behaviour |
|---|---|---|
| `--dry-run` / `--no-dry-run` | `--dry-run` | Nothing mutates unless `--no-dry-run` is passed explicitly |
| `--max-age-days` | `30` | AMIs older than this are candidates |
| `--keep-latest` | `3` | Newest N AMIs are always retained as rollback targets |
| `--project-tag` | `ticketing` | Only images carrying this `Project` tag are ever touched |
| `--include-orphan-snapshots` | off | Also sweep project-tagged snapshots with no parent AMI |
| `--region` | `ap-southeast-1` | Region to sweep |
| `--profile` | default chain | AWS named profile |

Safety rails, in the order they are applied:

1. Only self-owned AMIs tagged `Project=<tag>` are ever considered.
2. Any AMI referenced by a running/stopped instance or by any launch template
   version is retained — deleting one turns the next scale-out into a hard
   failure.
3. The newest `--keep-latest` images are retained regardless of age.
4. Everything else older than `--max-age-days` is deregistered, then its
   snapshots are deleted.
5. `InvalidSnapshot.InUse` is caught and logged rather than treated as an error,
   because a snapshot shared with another AMI must survive.

> Run this on a schedule (an EventBridge rule invoking a small Lambda, or a
> weekly CI job) rather than by hand. The whole point is that nobody remembers
> to do it manually, which is how the leak starts.

---

## Frequently asked questions

### Why not just use the stock EKS-optimized AMI with userdata?

You can, and for a small static cluster you probably should. See
[Where Packer's role ends](#where-packers-role-ends) — the honest answer is that
baking wins on boot-time variance under Spot churn and on producing an auditable
per-node baseline artifact, and loses on simplicity. If neither of those matters
to you, delete this directory.

### Why is there no amd64 build?

Every instance type on this platform is Graviton. A multi-arch matrix would
double build time and storage cost to produce an artifact nothing launches. If
an x86 node group is ever added, add `amazon-eks-node-al2023-x86_64-standard-*`
as a second source and let the `build` block fan out.

### Why does the build run Ansible twice?

The second pass should report `changed=0`. A baseline that reports changes on
re-application is not idempotent, which means it cannot be safely re-run against
a live node for drift correction and only works as a one-shot bake script. CI
greps the Packer log for `changed=0` on the second play. Packer itself cannot
fail a build on "changed" because Ansible exits 0 either way.

### The build fails with an RPM database lock error. Why?

The EKS-optimized AMI runs its own first-boot activity via cloud-init, and the
first Ansible `dnf` task can race it. The first shell provisioner calls
`cloud-init status --wait` for exactly this reason. If it still races, the base
image changed its first-boot behaviour — check `/var/log/cloud-init-output.log`
on the build instance with `-debug`.

### Does the AMI need to be rebaked for a Kubernetes version upgrade?

Yes. The kubelet and containerd shipped in the base image are matched to the
control-plane minor version. Bump `kubernetes_version`, rebake, and roll the
node group. Running a node more than one minor version behind the control plane
is unsupported.

### Where do secrets live?

Nowhere in this directory. No credential, connection string, or key is ever
baked into the AMI. Application secrets arrive at runtime through External
Secrets from AWS Secrets Manager; node-level AWS access is via the instance
profile and IRSA. An AMI is a shared, long-lived, copyable artifact and is the
wrong place for anything sensitive.

### How much does keeping old AMIs actually cost?

A 30 GiB gp3 snapshot in `ap-southeast-1` is roughly USD 0.05/GiB-month for the
changed blocks, so a typical node snapshot lands around USD 0.30-1.50/month.
That is trivially small until a pipeline has produced a hundred of them across a
year, which is exactly how this class of cost leak survives review.

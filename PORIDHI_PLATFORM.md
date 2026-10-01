# Poridhi Platform Guide

Context for Claude Code about how Poridhi works: the machines students get, how labs are delivered, how AWS labs work, and the behaviours that have broken real lab runs. **Read this before designing or writing any Poridhi lab.**

Most of what follows was learned the hard way while building and live-testing the 60-lab CKA series in this repo (`Poridhi Labs/CKA Labs/`). Every claim is marked:

- ✅ **Verified** — observed on a real Poridhi run
- ⚠️ **Unverified** — reasonable assumption, never confirmed. Test it before a lab depends on it.

When a lab relies on a ⚠️ item, say so to Adid and get it tested early.

---

## 1. What Poridhi is, and how a lab reaches a student

Poridhi.io is a hands-on learning platform. A student opens a lab in the browser, the platform provisions a fresh environment for that lab, and the student works through a Markdown lab document inside it.

- **Students work entirely in the browser.** ✅ There is no local machine setup. They use a browser-based **VS Code** (code-server) editor with an integrated terminal, or a web terminal.
- **Every lab launch is a brand-new environment.** ✅ Nothing survives from one lab to the next: not files, not installed tools, not running services, not credentials. See Section 3 — this is the single most important constraint.
- **Published labs are shown by title only, with no number.** ✅ A student never sees "Lab 14", so a lab must never refer to another lab by number. Refer to it by its title instead (details in Section 7).
- **Lab images are hosted in the `poridhiEng/lab-asset` GitHub repo.** ✅ The team replaces Mermaid diagrams with hand-drawn PNGs and adds terminal screenshots after testing.

---

## 2. The two kinds of lab environment

Poridhi offers two quite different environments. Know which one a lab uses before writing a single command.

| | **Poridhi VM (k3s cluster)** | **Poridhi VS Code workspace + AWS** |
|---|---|---|
| What the student gets | A Poridhi VM with a running k3s cluster; worker VMs added on demand | A Poridhi VM with AWS CLI + Terraform, plus a temporary AWS account |
| Where workloads run | On Poridhi's own VMs | On EC2 instances the student creates |
| Used for | Kubernetes labs (almost all of the CKA series) | Anything needing real Linux machines you fully control: kubeadm, custom networking, multi-machine systems |
| Cost to Poridhi | Fixed | **Per-hour EC2 billing — every lab must clean up** |

**The Multi-Tenant Agent Cloud course uses the AWS environment**, so Sections 5, 6 and 8 matter most. Section 4 is still useful, because the AWS workspace is itself a Poridhi VM.

---

## 3. The fresh-environment rule

✅ **Each lab launch is a completely new machine.** This caused more real mistakes in the CKA series than anything else.

- **"Fresh" means the whole machine, not just its data.** CLI tools installed in an earlier lab are gone — Helm, `etcdctl`, Python packages, anything. A lab that needs a tool must install it, in that lab, before first use.
- **Every lab must be fully self-contained.** If it needs a component another lab built, it must build that component itself, with the full command inline. Never write "use the X you set up in the previous lab" — it will always be missing.
- **Never write cleanup notes pointing at future labs.** "Leave this running for the next lab" is meaningless; the next lab gets a clean environment.
- **Referring to earlier *knowledge* is fine and encouraged.** "In the **Installing the NGINX Ingress Controller** lab you routed by host; this lab routes by path" costs nothing. The rule is only about things that must *exist*.
- **Repeating a setup step across labs is expected, not duplication.** If three labs need the same install, all three contain it.

### What this means for a course where labs build on each other

The Agent Cloud plan says *"each lab builds on the previous one"* and *"the reference solution for lab N is the codebase state after lab N."* That is fine for **code**, but not for the **environment**. At the start of Lab 05, the student has:

- no EC2 instances they can reach, because the workspace holding the SSH key and Terraform state was destroyed;
- no AWS credentials — they are session-scoped (Section 5.1);
- no clone of their repo, no running Postgres, Temporal, Authentik or agents.

So **every lab after the first needs a catch-up step** that rebuilds the previous lab's end state before the new work begins. The practical pattern:

1. Fresh credentials, then `terraform apply` from a provided configuration to recreate the machines
2. Clone the course repo at the previous lab's tag (e.g. `git checkout lab-04-solution`) — the plan's git-tag idea fits this well
3. One provided script that installs dependencies and starts everything the previous lab left running
4. A verification command proving the catch-up worked before the lab proper starts

⚠️ **Budget time for this.** Provisioning EC2 and bootstrapping took **5–8 minutes** in the CKA kubeadm labs, and the Agent Cloud stack is much heavier (Elasticsearch, Authentik, Temporal). Keep the catch-up scripted and non-interactive. A student should never redo earlier labs by hand.

---

## 4. The Poridhi VM itself

What is on the box, whether it's a k3s cluster node or the AWS workspace.

### 4.1 Operating system and user

- ✅ **Ubuntu 24.04.4 LTS**, but with a **custom 5.10 kernel** (`5.10.51` reported by `kubectl get nodes -o wide`). It is almost certainly a lightweight microVM rather than a standard cloud image.
- ⚠️ Because the kernel is custom, **some kernel modules are missing.** A k3s agent logged `Failed to load kernel module nft-chain-2-nat with modprobe`. **Never assume `modprobe vxlan`, `br_netfilter`, or other networking modules work on a Poridhi VM** without testing. Run networking labs that need them on EC2, where the kernel is standard.
- ✅ The user is **`poridhian`**. `sudo` works **without a password**.
- ✅ The terminal starts in **`~/code`** (prompt: `poridhian@<hash>:~/code$`).
- ✅ **Hostnames are random 16-character hex hashes** (e.g. `3e8908c381ab413b`), different on every launch. Never hardcode a hostname or node name.

### 4.2 Services running on the VM

✅ Seen in `systemctl list-units` on a real Poridhi VM:

| Service | What it is |
|---|---|
| `code-server.service` | The browser VS Code |
| `poridhi-terminal.service` | The browser web terminal (shows a "PORIDHI TERMINAL" banner) |
| `firstrun.service` | Poridhi's first-boot automation; on k3s labs it launches the cluster |
| `docker.service`, `containerd.service` | **Docker is installed and running** |
| `ssh.service` | OpenSSH server |
| `pnet.service` | Poridhi networking, likely related to the Netbird overlay (⚠️ purpose unconfirmed) |

✅ **`firstrun.service` is `Type=oneshot` with an `ExecStart` that never exits**, so it sits in `activating (start)` for the life of the VM. Anything it launched runs as a child in its cgroup. Two consequences seen on real runs:

- `systemctl start firstrun` **hangs forever**, because the unit never reaches `active`.
- Starting it again **re-runs the whole first-boot automation.** On a k3s VM that re-bootstrapped the cluster and wiped state. Never tell students to restart it.

### 4.3 Networking and addresses

A Poridhi VM has **two** addresses, and confusing them breaks labs:

| Address | Range | Used for |
|---|---|---|
| Internal / cluster IP | `10.6x.x.x` | Traffic between the lab's own VMs, e.g. Kubernetes node-to-node ✅ |
| **Netbird private IP** | `100.8x.x.x` | **SSH between Poridhi VMs** ✅ |

✅ **To SSH from one Poridhi VM to another, use the Netbird private IP.** Students find it in the **Cloud Tray → Private IP Info** table, which has a **Private IP** column for every node. SSHing to the `10.6x` address does not work.

✅ Worker-VM SSH credentials: user **`poridhian`**, password **`poridhi`**.

### 4.4 The Cloud Tray

✅ A panel in the Poridhi UI. Known functions:

- **K8s Worker Node** — set a count (max 3) and click **Add** to attach worker VMs to a k3s lab.
- **Private IP Info** — the Netbird SSH address of every node.
- **Credentials** — on AWS labs this shows the console link, username, password, **AccessKey**, **SecretKey**, and a **Poridhi-IAM** JWT.

### 4.5 Reaching a web UI from the browser: the Poridhi Load Balancer

✅ Students can't open `localhost:3000` in their own browser, because the service runs on a Poridhi VM. The **Poridhi Load Balancer** fixes this. Students create one in the Poridhi UI, pointing at an **IP and port**, and get a browser URL back. The CKA labs used it for Prometheus (NodePort 30090), Grafana (30300), Alertmanager and ArgoCD.

✅ **It cannot point at an EC2 public IP.** On an AWS lab (Lab 00, 2026-09-30), entering `52.221.225.232` with port `8000` in the Load Balancer form was rejected by the form's own validation: *"Please match the requested format. Please enter a valid IP address."* It only accepts some internal address format. Not needed anyway: see Section 8.3.

### 4.6 The AWS workspace's tools

✅ Checked on a real AWS lab workspace (Lab 00, 2026-09-30):

| | |
|---|---|
| OS / kernel | Ubuntu 24.04.4 LTS, kernel `5.10.51` |
| Size | 2 vCPU, ~3.9 GB RAM |
| Python | 3.12.3, with `pip3` 24.0 |
| Docker | 29.7.2, daemon running |
| Terraform | **1.5.2** (old: don't use syntax newer than 1.5) |
| AWS CLI | 2.36.32 |
| Also present | git 2.43, jq 1.7, curl 8.5, OpenSSH 9.6 |
| **Missing** | **`rsync`** |

### 4.7 VM sizes (k3s lab types)

✅ Standard k3s lab: roughly **2 vCPU / 2 GB** per node. ✅ A **larger lab type** exists with a **4 vCPU / 4 GB control plane** (workers unchanged). Heavy stacks such as Prometheus + Grafana crashed the 2 GB control plane and needed the larger type.

---

## 5. AWS labs

These all come from running the kubeadm labs (the **Building a Kubernetes Cluster from Scratch with kubeadm**, **Upgrading a Cluster with kubeadm** and **Diagnosing and Repairing a Broken Control Plane** labs) on real Poridhi AWS accounts.

### 5.1 Credentials

- ✅ Students copy an **AccessKey** and **SecretKey** from the Cloud Tray **Credentials** panel, then run `aws configure`. Region **`ap-southeast-1`**, AZ **`ap-southeast-1a`**.
- ✅ **The AWS account stays the same, but the IAM user changes every session** (e.g. `…/user/mk9m-poridhi`, then `…/user/1fbw-poridhi`). Credentials from a previous session fail with:
  ```
  InvalidClientTokenId: The security token included in the request is invalid.
  ```
  Terraform reports this as a provider error on `GetCallerIdentity`, which *looks* like a config bug but isn't. **Every AWS lab must tell students to fetch fresh credentials, and gate progress on `aws sts get-caller-identity` succeeding.**
- ✅ **New credentials reach STS before EC2.** `get-caller-identity` can succeed while the next EC2 call fails with `AuthFailure: AWS was not able to validate the provided access credentials`. Wait about a minute and retry. A read-only probe that prints `ap-southeast-1a`:
  ```bash
  aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text
  ```
  ✅ Don't use `describe-regions --query 'Regions[0].RegionName'`: it prints the first region in AWS's list (`ap-south-1`), which students read as a wrong-region error.
- ✅ Learn to tell the two apart: **`AuthFailure`** means the credentials aren't validated yet (wait or regenerate). **`UnauthorizedOperation`** means the credentials are valid but a policy forbids the action.
- ✅ Leftover `AWS_*` environment variables override `~/.aws/credentials`. `aws configure list` shows where each value really comes from. A stale `AWS_SESSION_TOKEN` alongside fresh keys causes `InvalidClientTokenId`.
- ✅ Real credentials were pasted into chat during testing. They're short-lived, but **never write real keys into a lab document or commit them**.

### 5.2 The IAM policy restricts instance types

✅ The lab user has one inline policy, **`RestrictedAccessPolicy`**, which only allows certain instance types. A disallowed type fails `RunInstances` with:
```
UnauthorizedOperation: … not authorized to perform: ec2:RunInstances … with an explicit deny in an identity-based policy
```

✅ **The full policy was read in Lab 00 (2026-09-30)** with `aws iam get-user-policy --user-name USER --policy-name RestrictedAccessPolicy`. Its instance-type rule is an explicit **Deny on `ec2:*` for any instance type other than `t2.micro`, `t2.small`, `t3.medium`**. Dry-run probes agree:

| Type | vCPU / RAM | Result |
|---|---|---|
| `t2.micro` | 1 / 1 GB | ALLOWED |
| `t2.small` | 1 / 2 GB | ALLOWED (per policy, not dry-run) |
| `t3.micro` | 2 / 1 GB | DENIED |
| `t3.small` | 2 / 2 GB | DENIED |
| **`t3.medium`** | **2 / 4 GB** | **ALLOWED** |
| `t2.medium` | 2 / 4 GB | DENIED |
| `t3.large`, `t3.xlarge`, `t3.2xlarge`, `m5.large`, `m5.xlarge`, `c5.xlarge` | — | DENIED |

✅ Other things the policy says:

- **All regional services are allowed only in `ap-southeast-1`** (condition `aws:RequestedRegion`): EC2, ELB, Auto Scaling, Lambda, S3, ECR, SQS, SNS, SES, Step Functions, API Gateway, VPC Lattice, and DynamoDB tables in that region.
- **Route 53 is not allowed at all** (not in the policy). Service Quotas (`servicequotas:GetServiceQuota`) and `iam:ListGroupsForUser` are denied too.
- ✅ **Elastic IPs: allowed** (`allocate-address --dry-run`), limit 5. They do **not** give stable URLs across sessions: every session destroys and recreates everything, so a new session gets a new address anyway.
- ✅ **Instance count:** `max-instances` attribute is 20, and **5 `t3.medium`s ran at the same time** without error.
- ✅ **EBS:** a 20 GB gp3 root volume is allowed.

✅ Other points:

- `sts decode-authorization-message` is **not** permitted, so the encoded failure message can't be decoded.
- `aws iam list-user-policies` works. `aws iam get-user-policy --policy-name RestrictedAccessPolicy` was never tried; it would reveal the full allow-list, and is worth running once.
- **Probe permissions with `--dry-run`**, which asks "would this be allowed?" without creating anything. `DryRunOperation` means allowed; `UnauthorizedOperation` means denied. Two gotchas seen on a real run: the account has **no default VPC**, so `--subnet-id` is required or it fails with `VPCIdNotSpecified`; and AWS CLI v2 prints a leading blank line, so match on the whole output rather than `head -1`:
  ```bash
  out=$(aws ec2 run-instances --image-id $AMI --instance-type t3.xlarge --count 1 \
        --subnet-id $SUBNET --dry-run 2>&1)
  case "$out" in
    *DryRunOperation*)       echo ALLOWED ;;
    *UnauthorizedOperation*) echo DENIED ;;
    *) echo "$out" ;;
  esac
  ```

### 5.2a EC2 instance facts (Lab 00, 2026-09-30)

✅ Stock Ubuntu 24.04 AMI (`ubuntu-noble-24.04-amd64-server-*`) on `t3.medium`:

| | |
|---|---|
| Kernel | `7.0.0-1013-aws` |
| Usable RAM | ~3.8 GB (3832 MB) |
| NIC | **`ens5`**, MTU **9001** (jumbo frames) |
| `vxlan` module | loads with `modprobe vxlan` |
| Python | 3.12.3 |
| rsync | present (3.2.7) |
| Docker | installed by `curl -fsSL https://get.docker.com \| sh` in `user_data` (got 29.8.1, the latest at the time) |
| Outbound | GitHub and Docker Hub pulls work |
| Instance ↔ instance | works on any port through the `self = true` rule |
| Workspace → EC2 public IP | works on an opened port |

✅ **Timing:** `terraform apply` for VPC + 5 instances took **49 s**. `user_data` Docker install finished **~43 s** after boot; all 5 were ready by the time the apply ended and SSH checks began.

### 5.3 Provisioning with Terraform

✅ **Terraform and the AWS CLI are preinstalled** in the workspace. Prefer Terraform over Pulumi: Pulumi needs a `pulumi login` token from Pulumi's website, which adds a signup step. Proven patterns, all working end to end:

- **Never hardcode an AMI ID** — they are region-specific and go stale. Look it up:
  ```hcl
  data "aws_ami" "ubuntu" {
    most_recent = true
    owners      = ["099720109477"]   # Canonical
    filter {
      name   = "name"
      values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
    }
  }
  ```
- **Network:** VPC `10.0.0.0/16`, public subnet `10.0.1.0/24` with `map_public_ip_on_launch = true`, internet gateway, and a route table sending `0.0.0.0/0` to the gateway.
- **Security group:** SSH from `0.0.0.0/0` (the workspace has no fixed IP), plus **one rule with `self = true`** allowing all traffic between instances in the group. That covers every internal port at once, including VXLAN UDP 4789, and avoids a cluster that half-works because one port was left out.
- **Key pair:**
  ```bash
  aws ec2 create-key-pair --key-name NAME --output text --query 'KeyMaterial' > NAME.id_rsa
  chmod 400 NAME.id_rsa
  ls -l NAME.id_rsa        # must be ~1.7 KB
  ```
  ✅ If the create fails, the error goes to stderr and empty stdout is still redirected, leaving a **zero-byte key file** that fails much later as an SSH error. Always `ls -l` it, and `rm -f` it before retrying.
- **SSH config written by Terraform** (`local_file` with `pathexpand("~/.ssh/config")`, mode `0600`, `StrictHostKeyChecking no`) lets students type `ssh master` instead of IPs.
- **The EC2 login user is `ubuntu`.** ✅
- **`user_data` bootstrap works.** ✅ A `templatefile()`-rendered script installed containerd, Kubernetes and a CNI, then ran `kubeadm init`/`join` unattended. Log it with `exec > /var/log/bootstrap.log 2>&1` so failures can be diagnosed.
- **Split the Terraform into several small `.tf` files, then run `terraform validate`** as a paste check (see Section 6).
- **`cd` into a project directory before writing `.tf` files.** The key-pair step leaves students in `~/.ssh`, and Terraform state landed among the SSH keys on a real run.
- ✅ Outbound internet from EC2 works: apt, `pkgs.k8s.io`, GitHub, Docker Hub.

### 5.4 Working across several machines

✅ **Only the workspace holds the SSH key and `~/.ssh/config`.** The EC2 instances cannot SSH to each other; running `ssh master` from a node fails with `Permission denied (publickey)`. So:

- **Label every command block with the machine it runs on** — e.g. *workspace*, *control-01*, *node-01*.
- Never nest `ssh node "…"` inside a step that already runs on another node.
- Students open each session **from the workspace**, usually in separate terminals.
- ✅ A real run showed students losing track of which machine they were on. Have them run `hostname` before anything destructive.

### 5.5 Cleanup and cost

- ✅ **Every AWS lab must end with `terraform destroy -auto-approve`**, then delete the key pair, then verify nothing is still running:
  ```bash
  aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text
  ```
  This should print nothing.
- ✅ **Terraform state lives in the workspace, which is destroyed at session end.** If a student closes the lab without destroying, a new session cannot `terraform destroy` those resources.
- ✅ **Poridhi cleaned the AWS account between sessions** in Lab 00: a tagged "canary" VPC deliberately left behind was gone in the next session. Don't rely on it always happening. **Every lab still starts with a leftover check** (`scripts/preflight.sh`: finds `ecs-lab-vpc` / `ecs-lab-key` by name and deletes them). A leftover key pair would otherwise make `terraform apply` fail with a duplicate key name.

---

## 6. Browser terminal gotchas

✅ All of these broke real lab runs. Build the workarounds in from the start.

- **Long heredoc pastes echo back garbled, but the file is usually fine.** A pasted `cat > file << 'EOF'` block often *echoes* with a jumbled last line such as `EOFags = { Name = "cka-cluster-sg" }`, which looks exactly like truncation. On real runs the files were intact. **Don't diagnose truncation from the echo.** After any heredoc that feeds something important, verify with a real check — `terraform validate`, `cat`, or a config linter — and keep heredocs short.
- **`grep` colourises output even through pipes.** Captured text gets invisible ANSI escape codes: `echo "$VAR"` looks right, but every command using it fails with `No such file or directory`. **Always use `grep --color=never` when capturing into a variable, file, or `$( )`.** This cost four debugging rounds on one lab.
- **Never put `<placeholder>` inside a shell command.** Bash reads `<` as input redirection, so `--token <token>` fails with `-bash: token: No such file or directory`. Use a shell variable set in an earlier step, or a placeholder like `TOKEN_HERE`.
- **`sudo` with a wildcard needs `sudo sh -c '…'`.** The user's shell expands `*` before `sudo` runs, so globs into root-only directories match nothing.
- **Backgrounding a process doesn't background its output.** `cmd &` still floods the terminal until the student can't type. Redirect: `cmd > /tmp/x.log 2>&1 &`. Use `nohup` if it must outlive the SSH session.
- **Escaped quotes inside `ssh host "…"` behave differently** from the same command run directly. Avoid nesting quoted commands in `ssh`.
- **Files without a trailing newline can hide their output** behind the next prompt. Add `; echo` after `cat`-ing such files in a verification step.
- **A process that finishes instantly can't be attached to.** `kubectl run --rm -i` against a fast container printed `couldn't attach … falling back to streaming logs`. Prefer a long-lived helper and `exec`, or curl directly from the node.
- **Always wait for asynchronous things.** Several steps failed only because the check ran seconds too early — a Pod not yet scheduled, a volume not yet bound, credentials not yet propagated. Use explicit waits (`kubectl wait`, `until … ; do sleep; done`, health-check loops) rather than bare `sleep`.

---

## 7. How Poridhi labs are written and tested

These conventions come from the CKA series. The new course has its own `CLAUDE.md` template; where the two conflict, Adid decides.

### 7.1 The testing loop

✅ **Adid runs every lab on a real Poridhi environment** and pastes the terminal output back. Claude then:

1. Compares each step's real output with the lab's "expected output"
2. Replaces invented output with real output, since expected output must never be fiction
3. Fixes any command that failed, and records **why** in the course's `CLAUDE.md`, so the same mistake doesn't recur in later labs

Expect several rounds per lab. In the CKA series, most first drafts had at least one step that failed on the real platform, for reasons no amount of reasoning predicted — the grep colour codes, a `firstrun` service that respawns processes, an IAM allow-list. **Treat untested commands as drafts.**

### 7.2 Publishing conventions

- ✅ **No lab numbers visible to students.** The H1 is the title alone. Cross-references use the other lab's title in bold: `the **Title** lab`. Numbers exist only in repo folder names. ⚠️ The new course's template (`# Lab NN — Title`) conflicts with this; confirm with Adid which applies to that course.
- ✅ **Mermaid diagrams are placeholders.** The team redraws them as PNGs (e.g. `images/labNN.png`) and swaps them in.
- ✅ **Screenshots replace expected output** where the team prefers — often after testing.
- ✅ **Images are hosted at:**
  ```
  https://raw.githubusercontent.com/poridhiEng/lab-asset/refs/heads/main/<Course%20Folder>/<Lab-XX>/images/<file>
  ```
  Spaces are URL-encoded (`CKA%20Labs`). Before publishing, **every image link must be a hosted URL** — no local `./images/…` paths left — and each should be checked for a `200` response. ✅ Hero diagrams are large (~1.4 MB each); compressing them would speed up page loads.
- ✅ **Collapsible `<details>` blocks render correctly** in the Poridhi lab viewer (checked in Lab 00), including a fenced code block inside. Use them for hints and hidden solutions.

### 7.3 Content conventions that worked

- Explain **why** before **how**; start from the problem.
- Explain every flag the first time it appears.
- Keep one concept per lab; 5–8 steps is the sweet spot.
- After a command that creates many things, say what now exists and where it runs.
- Include deliberate failures students can break and fix — they were consistently the strongest parts of the CKA labs.
- End every lab with cleanup, and with verification that proves the lab worked.

---

## 8. Implications for the Multi-Tenant Agent Cloud course

How the platform facts above collide with `lab-plan-bare-minimum.md`. **Resolve these before writing Lab 01.**

### 8.1 🔴 Only `t3.medium` is confirmed, so the platform is split across machines

An earlier plan put everything on one `t3.xlarge` (16 GB). The only instance types confirmed allowed are **`t2.micro` and `t3.medium` (4 GB)**, and a 16 GB all-in-one box may be impossible. Elasticsearch alone wants 2–4 GB, and Authentik plus its Postgres about 2 GB. The bare-minimum plan therefore uses a split layout of `t3.medium`s, provisioned per lab (the authoritative table is in `CLAUDE.md`):

| Machine | Runs |
|---|---|
| `control-01` | FastAPI, Postgres, Temporal, Temporal UI, Redis, Prometheus, Grafana |
| `obs-01` | Elasticsearch, Kibana |
| `auth-01` | Authentik |
| `node-01`, `node-02` | Agent, Docker, Fluent Bit, Node Exporter |

The capstone needs all five. ✅ Lab 00 confirmed that nothing larger than `t3.medium` is allowed, and that 5 `t3.medium`s run at once (§5.2).

### 8.2 🔴 Labs build on each other; environments don't persist

See Section 3. Every lab from 02 onward needs a **scripted catch-up**: Terraform recreates the machines, the repo is cloned at `lab-(N-1)-solution`, and one script restores the running services. That includes Authentik's configuration — groups, users, the OAuth provider — which must be **re-created by script or API**, not by clicking through its UI each session. Verify the result, then start the lab proper. **Design the catch-up mechanism as part of Lab 01**, not as an afterthought.

### 8.3 🔴 Reaching web UIs, and Authentik redirect URIs

Students need browser access to Temporal UI (8233), Authentik (9000), Kibana (5601), Grafana (3000) and the tenant web UI.

✅ **Decided: open the port in the security group and use the EC2 public IP.** Verified in Lab 00: a student's own browser loaded `http://<ec2-public-ip>:8000/` directly (Chrome shows "Not secure", since it's plain HTTP). It exposes the service to the internet, which is acceptable for a short-lived lab.

Ruled out: the **Poridhi Load Balancer** rejects public IPs (§4.5). **`ssh -L` tunnels** end on the workspace's localhost and aren't needed.

**Authentik makes this harder.** The OAuth redirect URI and issuer URL must exactly match the URL the browser uses, and **EC2 public IPs change on every provision** — so they change every lab. The redirect URI configuration must be **templated and re-applied by the catch-up script**. ✅ Elastic IPs are allowed but don't help: each session destroys and re-allocates them, so the address still changes between sessions. Test a real browser login through whichever access method is chosen **before** writing the SSO lab (Lab 06).

A second browser trap: **`crypto.subtle` (needed for PKCE S256) only exists in secure contexts**, meaning HTTPS or `localhost`. A page served from `http://<public-ip>:8000` doesn't have it, so the Web UI must let the control plane exchange the authorization code rather than doing PKCE in browser JavaScript.

### 8.4 Things that should just work on EC2

- ✅ **VXLAN** — EC2 runs a standard Ubuntu kernel, and the `self = true` security-group rule already allows UDP 4789 between instances. Don't try the VXLAN labs on a Poridhi VM, whose custom kernel may lack the modules.
- ✅ **Docker is not on the stock Ubuntu AMI**, and `curl -fsSL https://get.docker.com | sh` in `user_data` installs it in ~40 s.
- ✅ **The `vxlan` kernel module loads** on the EC2 kernel, and the NIC is `ens5`.
- ⚠️ **Elasticsearch needs `sudo sysctl -w vm.max_map_count=262144`** on its host, set persistently, and an explicit heap size to fit the instance's memory.
- ✅ **MTU is 9001** (jumbo frames), so VXLAN's ~50 bytes of overhead shouldn't bite. The VXLAN lab still verifies it with a large-packet ping.

### 8.5 Two "machines" students will confuse

The **workspace** (a Poridhi VM, holding the credentials, key and Terraform state) and the **EC2 instances** (where everything runs) are different computers. Label every command block with its machine, keep each machine in its own terminal, and have students check `hostname` before destructive steps (Section 5.4).

---

## 9. Open questions to test early

| # | Question | Why it matters |
|---|---|---|
| 1 | ✅ No. Only `t2.micro`, `t2.small`, `t3.medium` (§5.2) | Decides the whole machine layout (8.1) |
| 2 | ✅ 5 `t3.medium`s run at once; `max-instances` = 20 | A split layout needs about 5 |
| 3 | ✅ Yes: EC2 public IP + port opened in the security group | Every UI in the course depends on it (8.3) |
| 4 | ✅ No: its form rejects public IPs | Might be the cleanest answer to #3 |
| 5 | ✅ Account was cleaned between sessions; labs still run a leftover check (5.5) | Orphans, cost, leftover-check design (5.5) |
| 6 | ✅ Allowed, but don't survive sessions, so no help | Stable redirect URIs for Authentik (8.3) |
| 7 | ✅ Yes, `<details>` renders | Hidden solutions and hints |
| 8 | ✅ Workspace has Python 3.12.3 and a running Docker 29.7.2 (§4.6) | Whether anything can run locally before EC2 |
| 9 | ✅ Workspace has **no `rsync`**, so `push.sh` uses tar over ssh | `scripts/push.sh` depends on it |
| 10 | ✅ ~49 s apply + ~43 s Docker bootstrap (§5.2a) | Catch-up time budget (target < 10 min) |
| 11 | ✅ `ens5`, MTU 9001, `vxlan` loads, Python 3.12.3, Docker Hub OK (§5.2a) | VXLAN lab, agent runtime |
| 12 | ✅ 20 GB gp3 root volume allowed | Docker images for Elasticsearch, Temporal, Authentik need room |

Record each answer back into this file, moving it from ⚠️ to ✅, so the next person inherits facts instead of guesses.

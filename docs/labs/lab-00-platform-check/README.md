# Lab 00: Platform Check (author only, not published)

One Poridhi AWS session answers the open questions in `PORIDHI_PLATFORM.md` §9 before Lab 01 is written. Budget about 30–40 minutes, most of it waiting for EC2.

Everything the scripts print is also saved in `~/lab00-output/`. At the end, paste the contents of every file in that folder back to Claude.

## What this answers

| # | Question | Answered by |
|---|---|---|
| 1 | Are `t3.large`/`t3.xlarge`/bigger allowed? Full `RestrictedAccessPolicy`? | `probe.sh` §2–3 |
| 2 | Can 5 `t3.medium`s run at once? | `terraform apply` succeeding (or the error on instance 4/5) |
| 3 | Can your own browser reach an EC2 public IP + port? | Step 5 |
| 4 | Can the Poridhi Load Balancer target an EC2 public IP? | Step 6 |
| 5 | Does Poridhi clean the AWS account between sessions? | Step 8 (canary), checked next session |
| 6 | Are Elastic IPs allowed? | `probe.sh` §4 |
| 7 | Do `<details>` blocks render? | Step 9 |
| 8 | Workspace Python / Docker / tools? | `workspace-check.sh` |
| 9 | `rsync` in workspace and on EC2? | `workspace-check.sh`, `instance-check.sh` |
| 10 | How long do apply + Docker bootstrap take? | `time terraform apply`, `instance-check.sh` |
| 11 | EC2 NIC name, MTU, `vxlan` module, Python, Docker Hub pulls, instance↔instance traffic | `instance-check.sh` |
| 12 | Is a 20 GB root volume allowed? | `terraform apply` |

## Step 1: Get the kit into the workspace

Either clone the course repo (once it's pushed), or drag the `lab-00-platform-check` folder from your computer into the VS Code Explorer under `~/code`. Then, on the **workspace**:

```bash
cd ~/code/lab-00-platform-check
ls scripts terraform
```

The scripts are run with `bash script.sh`, so their executable bit doesn't matter.

## Step 2: Credentials and workspace facts

Fetch AccessKey/SecretKey from **Cloud Tray → Credentials**. On the **workspace**:

```bash
aws configure            # region ap-southeast-1, output json
aws sts get-caller-identity
aws ec2 describe-regions --region ap-southeast-1 --query 'Regions[0].RegionName' --output text
```

If the second command says `AuthFailure`, wait a minute and retry (credentials reach STS before EC2).

```bash
bash scripts/workspace-check.sh
```

## Step 3: Key pair and Terraform

On the **workspace**:

```bash
rm -f ~/.ssh/lab00-key.id_rsa
aws ec2 create-key-pair --key-name lab00-key --output text --query 'KeyMaterial' > ~/.ssh/lab00-key.id_rsa
chmod 400 ~/.ssh/lab00-key.id_rsa
ls -l ~/.ssh/lab00-key.id_rsa        # must be ~1.7 KB, not 0

cd ~/code/lab-00-platform-check/terraform
terraform init
terraform validate
time terraform apply -auto-approve
```

Note the `real` time printed at the end. If apply fails, **copy the full error** (it is the answer to question 2 or 12) and:

- error mentions the volume → `terraform apply -auto-approve -var root_volume_gb=8`
- error on instance 4 or 5 (cap) → `terraform apply -auto-approve -var instance_count=3`, and carry on

## Step 4: Probe and instance facts

On the **workspace**:

```bash
cd ~/code/lab-00-platform-check
bash scripts/probe.sh
bash scripts/instance-check.sh
```

`instance-check.sh` waits for every instance's Docker bootstrap (it prints how long each took), then collects facts from each one over SSH.

## Step 5: Browser access (question 3)

```bash
terraform -chdir=terraform output test_urls
```

Open one URL **in your own browser** (not the workspace). Expected page text: `hello from lab00-1`. Note whether it loads.

## Step 6: Poridhi Load Balancer (question 4)

In the Poridhi UI, create a Load Balancer pointing at the **public IP** of `lab00-1`, port `8000`. Does the URL it gives you show `hello from lab00-1`? If it only accepts private/Netbird IPs, note exactly what it says.

## Step 7: Clean up

```bash
bash scripts/cleanup.sh
```

Both leftover lists at the end must be empty.

## Step 8: Leftover canary (question 5, optional)

Create a free, empty, tagged VPC and deliberately leave it behind:

```bash
aws ec2 create-vpc --cidr-block 10.99.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=lab00-canary}]' --query Vpc.VpcId --output text
```

In your **next** Poridhi AWS session (any lab), run:

```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=lab00-canary" --query 'Vpcs[].VpcId' --output text
```

An ID printed means resources survive between sessions and Poridhi doesn't clean the account. Delete it with `aws ec2 delete-vpc --vpc-id VPC_ID_HERE`. Empty means the account was cleaned.

## Step 9: `<details>` rendering (question 7)

If you can preview a lab document in the Poridhi viewer, include this block and see whether it collapses:

<details>
<summary>Click to reveal the solution</summary>

```bash
echo "hidden until clicked"
```

</details>

## Paste back

- Every file in `~/lab00-output/` (`cat ~/lab00-output/*`)
- The `real` time from `terraform apply`, and any apply error
- Results of steps 5, 6, 8 (if done) and 9

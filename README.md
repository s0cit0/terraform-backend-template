# Terraform Remote Backend Template (AWS S3 + DynamoDB + KMS)

This starter repo shows how to wire Terraform to an AWS S3 backend that is protected by DynamoDB state locking and a customer-managed KMS key.

## At a glance

| Path | Purpose |
| --- | --- |
| `main.tf` | Sample output so `terraform plan` works out of the box |
| `providers.tf` | Default AWS provider configuration (region + tags) |
| `versions.tf` | Terraform and provider version pins + S3 backend stanza |
| `backend/*.example.hcl` | Environment-specific backend templates to copy locally |
| `Makefile` | Local workflow wrapper around `terraform fmt/init/validate` |
| `.github/workflows/terraform.yml` | CI workflow that enforces formatting and validation |
| `.github/dependabot.yml` | Weekly dependency update reminders |

## Prerequisites

- Terraform `>= 1.6.0, < 2.0.0`
- AWS CLI configured with credentials that can manage S3, DynamoDB, and KMS
- (Optional) GNU Make for the workflow helpers in the `Makefile`

> 💡 Tip: Use a dedicated AWS account or at least a dedicated region for remote state so you can restrict access tightly.

## Day 0 — Bootstrap the remote backend (one-time)

Follow these steps once per AWS account/region to create the S3 bucket, KMS key, and DynamoDB table that Terraform will use to store and lock state.

1. Set the identifiers you want to use and choose the AWS region:

   ```bash
   export BUCKET_NAME="my-terraform-state-bucket"
   export LOCK_TABLE="terraform-state-locks"
   export AWS_REGION="us-east-1"
   ```

2. Create an S3 bucket with secure defaults:

   ```bash
   if [ "$AWS_REGION" = "us-east-1" ]; then
     CREATE_BUCKET_OPTS=""
   else
     CREATE_BUCKET_OPTS="--create-bucket-configuration LocationConstraint=$AWS_REGION"
   fi

   aws s3api create-bucket      --bucket "$BUCKET_NAME"      $CREATE_BUCKET_OPTS      --region "$AWS_REGION"

   aws s3api put-public-access-block      --bucket "$BUCKET_NAME"      --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

   aws s3api put-bucket-versioning      --bucket "$BUCKET_NAME"      --versioning-configuration Status=Enabled
   ```

3. Create and alias a KMS key, then require it for the bucket:

   ```bash
   KMS_KEY_ARN=$(aws kms create-key --region "$AWS_REGION" --query 'KeyMetadata.Arn' --output text)
   aws kms create-alias      --alias-name "alias/terraform-state"      --target-key-id "$KMS_KEY_ARN"      --region "$AWS_REGION"

   aws s3api put-bucket-encryption      --bucket "$BUCKET_NAME"      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"'"'"$KMS_KEY_ARN"'"'""}}]}'
   ```

4. Provision the DynamoDB table for state locking:

   ```bash
   aws dynamodb create-table      --table-name "$LOCK_TABLE"      --attribute-definitions AttributeName=LockID,AttributeType=S      --key-schema AttributeName=LockID,KeyType=HASH      --billing-mode PAY_PER_REQUEST      --region "$AWS_REGION"
   ```

5. Record these four values somewhere safe—you will plug them into the backend configuration later:
   - S3 bucket name (`$BUCKET_NAME`)
   - S3 key prefix you plan to use (for example `my-team/dev/terraform.tfstate`)
   - DynamoDB table name (`$LOCK_TABLE`)
   - KMS key ARN (`$KMS_KEY_ARN`)

If secure equivalents already exist, you can reuse them and skip the AWS CLI commands above.

## Day 1 — Configure an environment backend file

Complete this section for every environment (dev, staging, prod, …) you want to manage with the template.

1. Pick an environment name and copy the matching template (never commit the real file):

   ```bash
   export TF_ENV="dev"  # or staging, prod, etc.
   cp "backend/${TF_ENV}.example.hcl" "backend/${TF_ENV}.hcl"
   ```

2. Edit `backend/${TF_ENV}.hcl` and replace the placeholders:
   - `<STATE_BUCKET_NAME>` → S3 bucket from Day 0
   - `<STATE_KEY_PATH>` → Unique object key for this environment (for example `my-app/${TF_ENV}/terraform.tfstate`)
   - `<AWS_REGION>` → Region the bucket lives in
   - `<DDB_LOCK_TABLE_NAME>` → DynamoDB table name
   - `<KMS_KEY_ARN>` → Full ARN of the KMS key

3. Initialize Terraform against that backend and verify the configuration:

   ```bash
   terraform init -reconfigure -backend-config="backend/${TF_ENV}.hcl"
   terraform plan  # should report "No changes" until you add resources
   ```

4. (Optional) If you prefer to manage state separation with Terraform workspaces, run `terraform workspace select $TF_ENV || terraform workspace new $TF_ENV` after `terraform init`.

## Day-to-day workflow for adding infrastructure

1. Export `TF_ENV` (or let CI set it) so your commands always target the correct backend file.
2. Pull the latest main branch and run `make init` once to download providers if `.terraform` does not exist yet.
3. Make your Terraform changes in `*.tf` files.
4. Run `make check` before opening a pull request. This executes:
   - `terraform fmt -recursive -check`
   - `terraform init -backend=false`
   - `terraform validate`
5. Run `terraform plan -var-file ...` as needed to review the actual changes.
6. Commit the Terraform files (and updated `.terraform.lock.hcl` when provider versions change). Never commit the real `backend/*.hcl` files.
7. Open a pull request and let CI rerun the same checks automatically.

## Working with multiple environments

- Keep each environment isolated with its own `backend/<env>.hcl` file. The repo ships templates for `dev`, `staging`, and `prod`; copy one to create more.
- Use unique S3 key paths per environment (for example `my-app/dev/terraform.tfstate`, `my-app/staging/terraform.tfstate`, `my-app/prod/terraform.tfstate`).
- For automation, export `TF_ENV` and reuse a consistent command sequence:

  ```bash
  export TF_ENV=staging
  terraform init -reconfigure -backend-config="backend/${TF_ENV}.hcl"
  terraform workspace select "$TF_ENV" 2>/dev/null || terraform workspace new "$TF_ENV"
  terraform plan
  ```

## Guardrails and automation

- **Makefile helpers.** See `make help` for documented commands that wrap the Terraform CLI. Running `make check` locally matches the CI checks.
- **Continuous integration.** `.github/workflows/terraform.yml` runs `terraform fmt -recursive -check`, `terraform init -backend=false`, and `terraform validate` on every pull request and relevant push. Fix failures before merging.
- **Dependabot.** `.github/dependabot.yml` opens weekly pull requests for Terraform modules and GitHub Actions so you can keep dependencies current.

## Keeping Terraform dependencies current

When Dependabot (or release notes) signal an update, follow this workflow:

1. Review the Terraform and provider release notes to understand breaking changes.
2. Adjust the version constraints in `versions.tf` if needed.
3. Run `terraform init -upgrade` to refresh provider plugins and update `.terraform.lock.hcl`.
4. Execute `make fmt` followed by `make validate` (or `make check`).
5. Run `terraform plan` for each environment to confirm no unexpected infrastructure changes occur.
6. Commit the version changes and the new lockfile, then merge after CI passes.

## What to commit

- Terraform configuration (`*.tf`) and generated `.terraform.lock.hcl`
- Template backend files (`backend/*.example.hcl`)
- Supporting docs and automation (`README.md`, `Makefile`, `.github/**`)

## What to keep local (never commit)

- Real backend configuration files (`backend/*.hcl` without the `.example` suffix)
- Any files containing secrets, AWS credentials, or environment-specific values

## Troubleshooting quick reference

| Symptom | Likely fix |
| --- | --- |
| `Invalid endpoint: https://s3..amazonaws.com` | Update the `region` in `backend/${TF_ENV}.hcl`, then rerun `terraform init -reconfigure`. |
| DynamoDB lock persists after a failed run | Delete the corresponding item in the DynamoDB table (`LockID` matches `s3://<bucket>/<key>`). |
| `AccessDenied` from AWS APIs | Grant the Terraform IAM principal least-privilege access: S3 (List/Get/Put/Delete), DynamoDB (PutItem/GetItem/DeleteItem/DescribeTable), and KMS (Encrypt/Decrypt/GenerateDataKey/DescribeKey). |

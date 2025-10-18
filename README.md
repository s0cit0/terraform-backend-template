TERRAFORM REMOTE BACKEND (AWS S3 + DynamoDB + KMS)

What it is:
- S3 stores the state (versioned, KMS-encrypted)
- DynamoDB provides a state lock
- KMS encrypts state at rest

Quick start:
1) **Bootstrap the remote backend infrastructure (one-time).**
   Use a dedicated AWS account/region for Terraform state and create the
   supporting resources. The snippet below shows secure defaults with the
   AWS CLI; update the `BUCKET_NAME`, `LOCK_TABLE`, and `AWS_REGION`
   variables before running. You must have permissions to manage S3,
   DynamoDB, and KMS.

   ```bash
   export BUCKET_NAME="my-terraform-state-bucket"
   export LOCK_TABLE="terraform-state-locks"
   export AWS_REGION="us-east-1"

   # Create an S3 bucket with Block Public Access, versioning, and default SSE-KMS.
   if [ "$AWS_REGION" = "us-east-1" ]; then
     CREATE_BUCKET_OPTS=""
   else
     CREATE_BUCKET_OPTS="--create-bucket-configuration LocationConstraint=$AWS_REGION"
   fi

   aws s3api create-bucket \
     --bucket "$BUCKET_NAME" \
     $CREATE_BUCKET_OPTS \
     --region $AWS_REGION

   aws s3api put-public-access-block \
     --bucket "$BUCKET_NAME" \
     --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

   aws s3api put-bucket-versioning \
     --bucket "$BUCKET_NAME" \
     --versioning-configuration Status=Enabled

   KMS_KEY_ARN=$(aws kms create-key --region $AWS_REGION --query 'KeyMetadata.Arn' --output text)
   aws kms create-alias --alias-name "alias/terraform-state" --target-key-id "$KMS_KEY_ARN" --region $AWS_REGION

   aws s3api put-bucket-encryption \
     --bucket "$BUCKET_NAME" \
     --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"'$KMS_KEY_ARN'"}}]}'

   # Create the DynamoDB table for state locking.
   aws dynamodb create-table \
     --table-name "$LOCK_TABLE" \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST \
     --region $AWS_REGION
   ```

   Record the bucket name, KMS key ARN, region, and DynamoDB table name for
   the backend configuration. If you already have secure equivalents, you
   can reuse them and skip these commands.

2) Choose the environment you want to work with and copy the matching
   backend template (never commit the real file):

   ```bash
   # Pick one: dev, staging, or prod. You can add more files later if needed.
   export TF_ENV="dev"

   cp "backend/${TF_ENV}.example.hcl" "backend/${TF_ENV}.hcl"
   ```

   Edit `backend/${TF_ENV}.hcl` and replace the placeholders:
   - `<STATE_BUCKET_NAME>`  (S3 bucket name that stores remote state)
   - `<STATE_KEY_PATH>`     (e.g., `my-app/${TF_ENV}/terraform.tfstate`)
   - `<AWS_REGION>`         (e.g., `us-east-1`)
   - `<DDB_LOCK_TABLE_NAME>`
   - `<KMS_KEY_ARN>`        (full ARN)

3) Initialize Terraform with the backend for that environment:
   terraform init -reconfigure -backend-config="backend/${TF_ENV}.hcl"

4) Sanity check (no resources yet):
   terraform plan
   Expect: "No changes."

### Working with multiple environments

- **File naming.** Keep each environment isolated by maintaining a
  dedicated `backend/<env>.hcl` file. The repo includes templates for
  `dev`, `staging`, and `prod`; add more by copying one of the examples
  and updating the placeholders.
- **State layout.** Use unique S3 keys per environment (for example
  `my-app/dev/terraform.tfstate`, `my-app/staging/terraform.tfstate`,
  `my-app/prod/terraform.tfstate`). The key path is freeform—pick
  something that clearly encodes the environment name.
- **Terraform workspaces (optional).** If you prefer to use workspaces to
  mirror your backend files, run `terraform workspace select $TF_ENV ||
  terraform workspace new $TF_ENV` before `terraform plan/apply`. Each
  workspace will reuse the backend config you passed to `terraform init`.
- **Automating selection.** Many teams export `TF_ENV` (or inject it via
  their CI system) and reuse the same command everywhere:

  ```bash
  export TF_ENV=staging
  terraform init -reconfigure -backend-config="backend/${TF_ENV}.hcl"
  terraform workspace select $TF_ENV 2>/dev/null || terraform workspace new $TF_ENV
  terraform plan
  ```

### Workflow guardrails

- **Local commands.** Run `make check` before opening a pull request. The
  provided `Makefile` wraps the recommended Terraform commands:
  - `make fmt` / `make fmt-check` for formatting
  - `make init` to download providers without contacting the remote backend
  - `make validate` to lint the configuration
- **Continuous integration.** A GitHub Actions workflow (`terraform.yml`)
  executes the same checks (`terraform fmt`, `terraform init -backend=false`,
  and `terraform validate`) on every push and pull request that touches
  Terraform files. Treat CI failures as a signal that the template or your
  changes need attention before merging.

### Keeping Terraform dependencies current

- **Update cadence.** Review Terraform core and AWS provider releases at
  least monthly. Allow patch updates freely; plan minor version bumps when the
  release notes indicate breaking changes or new capabilities you need.
- **Automated reminders.** Dependabot (`.github/dependabot.yml`) will raise
  weekly pull requests for new Terraform and GitHub Actions versions so you
  know when updates are available.
- **Upgrade procedure.** When ready to upgrade:
  1. Adjust version constraints in `versions.tf` if necessary.
  2. Run `terraform init -upgrade` to refresh provider plugins and update
     `.terraform.lock.hcl`.
  3. Execute `make fmt` and `make validate` (or `make check`) to ensure the
     configuration still passes formatting and validation.
  4. Review the Terraform and provider release notes for breaking changes,
     then run `terraform plan` against each environment before merging.

What to commit:
- *.tf files, .terraform.lock.hcl (generated by init), backend/*.example.hcl, .gitignore, README.md

What to keep local (not committed):
- backend/*.hcl (real values for each environment; keep the `.example.hcl` files tracked)

Troubleshooting:
- Invalid endpoint (s3..amazonaws.com): fix `region` in `backend/${TF_ENV}.hcl` and re-run init.
- State lock error: a lock exists in DynamoDB; remove the item for s3://<bucket>/<key>.
- Access denied: ensure IAM can use S3 (List/Get/Put/Delete), DynamoDB (Put/Get/Delete/Describe), KMS (Encrypt/Decrypt/GenerateDataKey/DescribeKey).

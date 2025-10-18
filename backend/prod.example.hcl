bucket         = "<STATE_BUCKET_NAME>"            # e.g., org-shared-tfstate-123456789012-us-east-1
key            = "<STATE_KEY_PATH>"               # e.g., my-app/prod/terraform.tfstate
region         = "<AWS_REGION>"                   # e.g., us-east-1
dynamodb_table = "<DDB_LOCK_TABLE_NAME>"          # e.g., org-prod-tf-locks
encrypt        = true
kms_key_id     = "<KMS_KEY_ARN>"                  # e.g., arn:aws:kms:us-east-1:123456789012:key/abcd-...

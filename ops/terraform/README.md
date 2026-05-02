# terraform/ — IaC examples (stub)

Reference Terraform modules to provision the cloud-side of a Marbles
Game deployment. Not written yet; this README scopes the work.

We intend to ship **two reference modules** so an operator can pick
the cloud they already use:

| Module       | What it provisions                                          |
| ------------ | ----------------------------------------------------------- |
| `aws/`       | ECS Fargate (rgsd + replayd), S3 (replays), RDS Postgres, ALB, CloudWatch logs, IAM roles. |
| `gcp/`       | Cloud Run (rgsd + replayd), GCS (replays), Cloud SQL Postgres, HTTPS LB, Cloud Logging, Workload Identity. |

Both modules expose the same input variables so the operator-facing
README ("how to deploy") is the same regardless of cloud:

```hcl
module "marbles_game" {
  source = "github.com/onion-coding/marbles-game//ops/terraform/aws?ref=v0.11.0"

  region          = "eu-central-1"
  rtp_bps         = 9500
  marbles         = 20
  buy_in          = 100
  hmac_secret_arn = aws_secretsmanager_secret.rgsd.arn   # AWS module variant
  wallet_url      = "https://wallet.operator.example/v1"
  domain          = "rgs.example.com"
  acm_cert_arn    = aws_acm_certificate.rgs.arn
}
```

## TODO before phase-1 release

1. Implement `aws/` module:
   - VPC + 2 private subnets + 2 public subnets in different AZs
   - ECS Fargate cluster + service for rgsd (1 task, scale-up later)
   - ECS Fargate cluster + service for replayd (2 tasks, ALB target)
   - ALB with two target groups (`/v1/*` → rgsd, `/`/`/rounds/*` → replayd)
   - RDS Postgres single-AZ for dev, Multi-AZ for prod (var)
   - S3 bucket with object-lock for replay archive (write-once)
   - Secrets Manager entry for `RGSD_HMAC_SECRET` + rotation lambda
   - CloudWatch log groups, retention 30 days
   - IAM roles least-privilege (rgsd reads HMAC secret + writes S3,
     replayd reads S3, that's it).
2. Implement `gcp/` module with the same surface against Cloud Run +
   Cloud SQL + GCS.
3. Write `terraform/README.md` (this file → fold into) with full
   `terraform plan` walk-through.
4. Add a `terraform/azure/` module if a customer asks for it (don't
   pre-build).
5. Add `tflint` and `tfsec` to CI for the IaC; one of them should
   block on "S3 bucket without object-lock" specifically — a regulator
   will fail the audit if replay storage isn't write-once.

## Why no Pulumi / CDKtf / SST

Terraform has the widest operator-side adoption and the best provider
ecosystem for boring infra. A second tool means a second style of bug
without much upside. If a customer specifically asks for Pulumi we
can hand-translate; otherwise this stays Terraform.

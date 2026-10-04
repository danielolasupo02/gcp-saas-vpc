# --- Variables ---
export PROJECT_ID="saas-vpc-host-$RANDOM"
export BILLING_ACCOUNT=$(gcloud billing accounts list --format="value(name.basename())" --limit=1)
export SA_EMAIL="network-admin-sa@${PROJECT_ID}.iam.gserviceaccount.com"
echo "Project: $PROJECT_ID | Billing: $BILLING_ACCOUNT"

# --- Create project and link billing (APIs won't enable without billing) ---
gcloud projects create "$PROJECT_ID" --name="Enterprise SaaS VPC Project"
# with an org, add: --organization=ORG_ID
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
gcloud config set project "$PROJECT_ID"

# --- Enable APIs (compute.googleapis.com is the "VPC Network API") ---
gcloud services enable \
  compute.googleapis.com \
  vpcaccess.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  dns.googleapis.com \
  iap.googleapis.com \
  billingbudgets.googleapis.com

# --- Service account and roles ---
gcloud iam service-accounts create network-admin-sa \
  --display-name="Network Admin Service Account"

for ROLE in roles/compute.networkAdmin roles/compute.securityAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None
done

# --- Let YOU impersonate the SA (no key files) ---
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator"

# --- Budget alert at 50/90/100% of $20 ---
gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="saas-vpc-budget" \
  --budget-amount=20USD \
  --filter-projects="projects/${PROJECT_ID}" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0

  # --- Verify Step  ---
  gcloud services list --enabled --filter="name:(compute.googleapis.com vpcaccess.googleapis.com)"

  gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:${SA_EMAIL}" \
    --format="table(bindings.role)"

  # Test impersonation works
  gcloud compute networks list --impersonate-service-account="$SA_EMAIL"
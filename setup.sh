#!/bin/bash

# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

PROJECT_NUMBER="$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")"
export PROJECT_NUMBER
export TOKEN=$(gcloud auth print-access-token)

add_secret(){
  local SECRET_ID=$1
  local SECRET_VALUE=$2
  echo "Creating Secret $SECRET_ID in Project $PROJECT_ID"
  gcloud secrets create "$SECRET_ID" --replication-policy="automatic" --project "$PROJECT_ID"
  echo -n "$SECRET_VALUE" | gcloud secrets versions add "$SECRET_ID" --project "$PROJECT_ID" --data-file=- 
  echo "Secret $SECRET_ID created successfully"
}

publish_integration(){
  local integration=$1
  echo "Publishing $integration Integration"
  # sed -i "s/PROJECT_ID/$PROJECT_ID/g" $integration/connectors/sfdc-connection.json
  integrationcli integrations apply -f $integration/. -p "$PROJECT_ID" -r "$GCP_PROJECT_REGION" -t "$TOKEN" -g --skip-connectors
}

echo "Installing dependecies like unzip and cosign"
apt-get install -y unzip
wget "https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64"
mv cosign-linux-amd64 /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign

gcloud config set project $PROJECT_ID

echo "Installing integrationcli"
curl -L https://raw.githubusercontent.com/GoogleCloudPlatform/application-integration-management-toolkit/main/downloadLatest.sh | sh -
export PATH=$PATH:$HOME/.integrationcli/bin

echo "Assigning roles to Default compute service account"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.viewer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

export SFDC_USER_PASS="$(gcloud compute instances describe lab-startup --project ${PROJECT_ID} --zone ${GCP_PROJECT_ZONE}  --format=json | jq -r '.metadata.items[] | select(.key == "sfdcUserPass") | .value')"
export SFDC_SEC_TOKEN="$(gcloud compute instances describe lab-startup --project ${PROJECT_ID} --zone ${GCP_PROJECT_ZONE}  --format=json | jq -r '.metadata.items[] | select(.key == "sfdcSecToken") | .value')"

add_secret "user-sfdc-password" "${SFDC_USER_PASS}" # TODO
add_secret "sfdc-secret-token" "${SFDC_SEC_TOKEN}" # TODO

sleep 30

echo "Creating Connector sfdc-connection"
sed -i "s/PROJECT_ID/$PROJECT_ID/g" sfdc-leads/connectors/sfdc-connection.json
integrationcli connectors create -n sfdc-connection -f sfdc-leads/connectors/sfdc-connection.json -p "$PROJECT_ID" -r "$GCP_PROJECT_REGION" -t "$TOKEN" -g
sleep 300

echo "Retrying Connector creation"
integrationcli connectors create -n sfdc-connection -f sfdc-leads/connectors/sfdc-connection.json -p "$PROJECT_ID" -r "$GCP_PROJECT_REGION" -t "$TOKEN" -g


publish_integration "sfdc-leads"
publish_integration "sfdc-tasks"
publish_integration "sfdc-opportunity"

echo "Cleanup metadata"
gcloud compute instances remove-metadata lab-startup --project="${PROJECT_ID}" --zone="${GCP_PROJECT_ZONE}" --keys=sfdcSecToken,sfdcUserPass
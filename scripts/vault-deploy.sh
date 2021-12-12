#!/usr/bin/env bash

# shellcheck disable=SC1091
# shellcheck disable=SC2086

source "scripts/lib-functions.sh"

_usage() {
  echo -e "\n Usage: $(basename ${0})"
  echo -e "\t -p <google_project>   - GCP Project ID (required)"
  echo -e "\t -d <vault_dns_name>   - Vault GKE DNS Name (required)"
  echo -e "\t -g <google_gke_name>  - GKE cluster name (optional)"
  echo -e "\t -t                    - Enable test/debug mode (optional)"
  echo -e "\n Example:"
  echo -e "\t $(basename ${0}) -p <google_project> -d <vault_dns_name>"
  exit 1
}

while getopts "p:d:g:t" option; do
  case ${option} in
  p)
    google_project=${OPTARG}
    ;;
  d)
    vault_dns_name=${OPTARG}
    ;;
  g)
    google_gke_name=${OPTARG}
    ;;
  t)
    debug_flags="--debug --dry-run"
    ;;
  *)
    _usage
    ;;
  esac
done

if [[ -z "${vault_dns_name}" || -z ${google_project} ]]; then
  _usage
fi

_validate_google_project_name ${google_project}
_get_terraform_output_file ${google_project}
_validate_vault_dns_name ${vault_dns_name}

vault_version="1.8.5"
vault_service_account=$(jq -r ".vault_service_account.value // empty" ${terraform_output_file:?})
vault_ip_address=$(jq -r ".vault_dns_records.value[] | select(.name==\"${vault_dns_name}\") | .address // empty" ${terraform_output_file})

google_region="$(jq -r ".google_region.value // empty" ${terraform_output_file:?})"
google_gke_name=${google_gke_name:-$(jq -r ".gke_names.value[0] // empty" ${terraform_output_file:?})}
google_docker_repo="${google_region:?}-docker.pkg.dev/${google_project}/containers"

gcloud container clusters get-credentials "${google_gke_name:?}" --region="${google_region:?}"

secret_version=$(gcloud secrets versions list "${vault_dns_name}-tls-crt" --sort-by=name --limit=1 --format="value(name)")
vault_tls_crt=$(gcloud secrets versions access --secret="${vault_dns_name}-tls-crt" "${secret_version:?}" | base64 --wrap=0)
secret_version=$(gcloud secrets versions list "${vault_dns_name}-tls-key" --sort-by=name --limit=1 --format="value(name)")
vault_tls_key=$(gcloud secrets versions access --secret="${vault_dns_name}-tls-key" "${secret_version:?}" | base64 --wrap=0)
tls_ca=$(jq -r ".root_ca_certificate.value // empty" ${terraform_output_file:?} | base64 --wrap=0)

_connect_gke_proxy

echo -e "\nRunning HELM deployment\n"

helm upgrade "${vault_dns_name}" "kubernetes/vault/" \
  --install \
  --create-namespace \
  --namespace "${vault_dns_name}" \
  --reset-values \
  --atomic \
  --wait \
  --timeout 3m \
  --cleanup-on-fail \
  --set "global.googleRegion=${google_region}" \
  --set "server.tlsCrt=${vault_tls_crt:?}" \
  --set "server.tlsKey=${vault_tls_key:?}" \
  --set "server.tlsCA=${tls_ca:?}" \
  --set "server.extraEnvironmentVars.GOOGLE_PROJECT=${google_project}" \
  --set "server.extraEnvironmentVars.GOOGLE_REGION=${google_region}" \
  --set "server.serviceAccount.annotations=iam.gke.io/gcp-service-account: ${vault_service_account:?}" \
  --set "server.image.repository=${google_docker_repo:?}/vault" \
  --set "server.image.tag=${vault_version:?}" \
  --set "server.serviceActive.loadBalancerIP=${vault_ip_address:?}" ${debug_flags}
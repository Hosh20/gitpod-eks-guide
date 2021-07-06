#!/bin/bash

set -euo pipefail

function variables_from_context() {
    # Create EKS cluster without nodes
    # Generate a new kubeconfig file in the local directory
    KUBECONFIG=".kubeconfig"

    # extract details form the ecktl configuration file
    CLUSTER_NAME=$(yq eval '.metadata.name' "${EKSCTL_CONFIG}")
    AWS_REGION=$(yq eval '.metadata.region' "${EKSCTL_CONFIG}")

    ACCOUNT_ID=$(aws sts get-caller-identity | jq -r .Account)

    export KUBECONFIG
    export CLUSTER_NAME
    export AWS_REGION
    export ACCOUNT_ID
}

function check_ekctl_file() {
    EKSCTL_CONFIG=$1
    if [ ! -f "${EKSCTL_CONFIG}" ]; then
        echo "Configuration file ${EKSCTL_CONFIG} does not exist."
        exit 1
    fi

    export EKSCTL_CONFIG
}

# Bootstrap AWS CDK - https://docs.aws.amazon.com/cdk/latest/guide/bootstrapping.html
function ensure_aws_cdk() {
    pushd /tmp; cdk bootstrap "aws://${ACCOUNT_ID}/${AWS_REGION}"; popd
}

function install() {
    check_ekctl_file "$1"
    variables_from_context
    ensure_aws_cdk

    # Check the Certificate exists
    # shellcheck disable=SC2034
    CERT_DETAILS=$(aws acm describe-certificate --certificate-arn "${CERTIFICATE_ARN}" --region "${AWS_REGION}")
    if [ $? -eq 1 ]; then
        echo "The secret ${CERTIFICATE_ARN} does not exist."
        exit 1
    fi

    if ! eksctl get cluster "${CLUSTER_NAME}" > /dev/null 2>&1; then
        # https://eksctl.io/usage/managing-nodegroups/
        eksctl create cluster --config-file "${EKSCTL_CONFIG}" --without-nodegroup --kubeconfig ${KUBECONFIG}
    fi

    # Disable default AWS CNI provider.
    # The reason for this change is related to the number of containers we can have in ec2 instances
    # https://github.com/awslabs/amazon-eks-ami/blob/master/files/eni-max-pods.txt
    # https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html
    kubectl patch ds -n kube-system aws-node -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-calico": "true"}}}}}'
    # Install Calico opetator.
    kubectl apply -f https://docs.projectcalico.org/manifests/tigera-operator.yaml

    # Create Calico CNI installation
  kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - blockSize: 26
        cidr: 172.16.0.0/16
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
    linuxDataplane: Iptables
  cni:
    type: Calico
  kubernetesProvider: EKS
  flexVolumePath: /var/lib/kubelet/plugins
EOF

    # Setup Calico
    kubectl create namespace calico-system > /dev/null 2>&1 || true
  kubectl apply -f - <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kubernetes-services-endpoint
  namespace: calico-system
data:
  # extract load balanced domain name created by EKS
  KUBERNETES_SERVICE_HOST: $(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text --region "${AWS_REGION}")
  KUBERNETES_SERVICE_PORT: "443"
EOF

    if aws iam get-role --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" > /dev/null 2>&1; then
        KUBECTL_ROLE_ARN=$(aws iam get-role --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" | jq -r .Role.Arn)
    else
        echo "Creating Role for EKS access"
        # Create IAM role and mapping to Kubernetes user and groups.
        POLICY=$(echo -n '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'; echo -n "$ACCOUNT_ID"; echo -n ':root"},"Action":"sts:AssumeRole","Condition":{}}]}')
        KUBECTL_ROLE_ARN=$(aws iam create-role \
            --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" \
            --description "Kubernetes role (for AWS IAM Authenticator for Kubernetes)." \
            --assume-role-policy-document "$POLICY" \
            --output text \
            --query 'Role.Arn')
    fi
    export KUBECTL_ROLE_ARN

    # check if the identity mapping already exists
    # Manage IAM users and roles https://eksctl.io/usage/iam-identity-mappings/
    if ! eksctl get iamidentitymapping --cluster "${CLUSTER_NAME}" --arn "${KUBECTL_ROLE_ARN}" > /dev/null 2>&1; then
        echo "Creating mapping from IAM role ${KUBECTL_ROLE_ARN}"
        eksctl create iamidentitymapping \
            --cluster "${CLUSTER_NAME}" \
            --arn "${KUBECTL_ROLE_ARN}" \
            --username eksadmin \
            --group system:masters
    fi

    # Create cluster nodes defined in the configuration file
    eksctl create nodegroup --config-file="${EKSCTL_CONFIG}"

    # Restart tigera-operator
    kubectl delete pod -n tigera-operator -l k8s-app=tigera-operator > /dev/null 2>&1

    # Create RDS database, S3 bucket for docker-registry and IAM account for gitpod S3 storage
    # the cdk application will generates a gitpod-values.yaml file to be used by helm

    # TODO: remove once we can reference a secret in the helm chart.
    # generated password cannot excede 41 characters (RDS limitation)
    SSM_KEY="/gitpod/cluster/${CLUSTER_NAME}/region/${AWS_REGION}"
    aws ssm put-parameter \
        --overwrite \
        --name "${SSM_KEY}" \
        --type String \
        --value "$(date +%s | sha256sum | base64 | head -c 35 ; echo)" \
        --region "${AWS_REGION}" > /dev/null 2>&1

    # Bootstrap AWS CDK - https://docs.aws.amazon.com/cdk/latest/guide/bootstrapping.html
    pushd /tmp; cdk bootstrap "aws://${ACCOUNT_ID}/${AWS_REGION}"; popd

    # deploy CDK stacks
    cdk deploy \
        --context clusterName="${CLUSTER_NAME}" \
        --context region="${AWS_REGION}" \
        --context domain="${DOMAIN}" \
        --context certificatearn="${CERTIFICATE_ARN}" \
        --context identityoidcissuer="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text --region "${AWS_REGION}")" \
        --require-approval never \
        --all

    # wait for update of the ingress status
    sleep 5

    ALB_URL=$(kubectl get ingress gitpod -o json | jq -r .status.loadBalancer.ingress[0].hostname)
    if [ -n "${ALB_URL}" ];then
        printf '\nLoad balancer hostname: %s\n' "${ALB_URL}"
    fi
}

function uninstall() {
    check_ekctl_file "$1"
    variables_from_context

    KUBECTL_ROLE_ARN=$(aws iam get-role --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" | jq -r .Role.Arn)
    export KUBECTL_ROLE_ARN

    cdk destroy \
        --context clusterName="${CLUSTER_NAME}" \
        --context region="${AWS_REGION}" \
        --context domain="${DOMAIN}" \
        --context certificatearn="${CERTIFICATE_ARN}" \
        --context identityoidcissuer="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text --region "${AWS_REGION}")" \
        --require-approval never \
        --all

    cdk context --clear
    eksctl delete cluster "${CLUSTER_NAME}"
}

function main() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 [--install|--uninstall]"
        exit
    fi

    case $1 in
        '--install')
            install "eks-cluster.yaml"
        ;;
        '--uninstall')
            uninstall "eks-cluster.yaml"
        ;;
        *)
            echo "unknown command $1, Usage: $0 [--install|--uninstall]"
        ;;
    esac
    echo "done"
}

main "$@"

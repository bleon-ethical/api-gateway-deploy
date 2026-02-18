#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

aws eks update-kubeconfig --region "${AWS_DEFAULT_REGION}" --name "${INPUT_EKS_CLUSTER_NAME}"

ENVIRONMENT=${INPUT_ENVIRONMENT:-"default"}
PROJECT=${INPUT_PROJECT}
NAMESPACE=${INPUT_NAMESPACE:-"cpat"}
SERVICE_NAME=${INPUT_SERVICE_NAME}

NLB_LIST=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?Type==`network`].[LoadBalancerArn, DNSName]' --output json)

EKS_SERVICE_HOSTNAME=$(kubectl get services -l "cpat.service=${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

if [ -z "$EKS_SERVICE_HOSTNAME" ]; then
    exit 1
fi

ARN=$(echo "$NLB_LIST" | jq --arg h "$EKS_SERVICE_HOSTNAME" -r '.[] | select(.[1] == $h) | .[0]')

if [ -z "$ARN" ]; then
    exit 1
fi

VPC_LINK_ID=$(aws apigateway get-vpc-links --query "items[?targetArns[0]=='$ARN'].id" --output text)

if [ -z "$VPC_LINK_ID" ] || [ "$VPC_LINK_ID" == "None" ]; then
    VPC_LINK_NAME="${PROJECT}-${SERVICE_NAME}-${ENVIRONMENT}-link"
    
    VPC_LINK_RES=$(aws apigateway create-vpc-link \
        --name "$VPC_LINK_NAME" \
        --description "Link para API servicio $SERVICE_NAME" \
        --target-arns "$ARN" \
        --tags "Environment=$ENVIRONMENT,Project=$PROJECT,Purpose=API")

    VPC_LINK_ID=$(echo "$VPC_LINK_RES" | jq -r '.id')
fi

API_NAME="${PROJECT}-${ENVIRONMENT}-${SERVICE_NAME}-api"
cp "./$INPUT_SWAGGER_PATH" ./swagger_temp.yaml

sed -i "s|API_NAME|${API_NAME}|g" ./swagger_temp.yaml
sed -i "s|ACCOUNT_ID|${ACCOUNT_ID}|g" ./swagger_temp.yaml
sed -i "s|REGION|${AWS_DEFAULT_REGION}|g" ./swagger_temp.yaml
sed -i "s|CORS_DOMAIN|${INPUT_CORS_DOMAIN}|g" ./swagger_temp.yaml

API_DATA=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME']" --output json)
ID=$(echo "$API_DATA" | jq -r '.[0].id // empty')

if [ -z "$ID" ]; then
    API_RES=$(aws apigateway create-rest-api --name "$API_NAME" \
                        --endpoint-configuration "types=REGIONAL" \
                        --description "API Gateway servicio $SERVICE_NAME")
    ID=$(echo "$API_RES" | jq -r '.id')
fi

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    base64 -w 0 ./swagger_temp.yaml > ./swagger_body.b64
else
    base64 ./swagger_temp.yaml > ./swagger_body.b64
fi

aws apigateway put-rest-api --rest-api-id "$ID" --mode overwrite --body "file://./swagger_temp.yaml"

EXISTS_DEPLOYMENT=$(aws apigateway get-deployments --rest-api-id "$ID" --query "items" --output json | jq '. | length')

if [ "$EXISTS_DEPLOYMENT" -eq 0 ]; then
    aws apigateway create-deployment \
        --rest-api-id "$ID" \
        --stage-name "$INPUT_STAGE_NAME" \
        --variables "url=$EKS_SERVICE_HOSTNAME,vpcLinkId=$VPC_LINK_ID,cpat_authorizer=$INPUT_AUTHORIZER_FUNCTION,cpat_authorizer_role=$INPUT_AUTHORIZER_ROLE_NAME" 
else
    DEPLOYMENT_ID=$(aws apigateway get-deployments --rest-api-id "$ID" --query "items[0].id" --output text)
    aws apigateway create-deployment --rest-api-id "$ID" --stage-name "$INPUT_STAGE_NAME"
fi

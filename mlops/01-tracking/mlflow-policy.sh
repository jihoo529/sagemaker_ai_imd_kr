#!/bin/bash
###############################################################################
# mlflow-policy.sh
#
# SageMaker Execution Role에 MLflow Tracking Server 접근 권한을 추가하는 스크립트
#
# [사용법]
#   1. AWS Console 우측 상단 >_ 아이콘 클릭 → CloudShell 열기
#   2. CloudShell 상단 Actions → Upload file → 이 파일 업로드
#   3. 실행: bash mlflow-policy.sh
#
# [주의사항]
#   - 반드시 CloudShell에서 실행 (콘솔 로그인 유저 권한 필요)
#   - SageMaker 노트북/터미널에서는 IAM 수정 권한 없어서 실행 불가
#   - 모든 값 (Account ID, Region, Role, Tracking Server ARN) 은 자동 감지됨
#
# [해결하는 문제]
#   MlflowException: API request to endpoint /api/2.0/mlflow/experiments/get-by-name
#   failed with error code 403 != 200
#   → sagemaker-mlflow:* 권한 부재
###############################################################################

set -e

echo "=============================================="
echo " MLflow Access Policy Setup"
echo "=============================================="

# ----------------------------------------------------------------------------
# 1) Account ID 자동 감지
# ----------------------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
  echo "ERROR: AWS Account ID 를 감지할 수 없습니다. AWS CLI 인증 상태를 확인하세요."
  exit 1
fi
echo "[1/4] Detected Account ID    : $ACCOUNT_ID"

# ----------------------------------------------------------------------------
# 2) Region 자동 감지 (환경변수 → CLI config 순서)
# ----------------------------------------------------------------------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"
if [ -z "$REGION" ]; then
  echo "ERROR: AWS Region 을 감지할 수 없습니다. AWS_REGION 환경변수를 설정하세요."
  exit 1
fi
echo "[2/4] Detected Region        : $REGION"

# ----------------------------------------------------------------------------
# 3) SageMaker Execution Role 자동 감지
#    우선순위:
#      (a) SageMaker Domain 의 DefaultExecutionRole
#      (b) 현재 caller identity 에서 추출 (SageMaker 노트북/터미널에서 실행 시)
# ----------------------------------------------------------------------------
ROLE_ARN=""
ROLE_NAME=""

# (a) SageMaker Domain 에서 Execution Role 찾기
DOMAIN_ID=$(aws sagemaker list-domains --region "$REGION" \
  --query 'Domains[0].DomainId' --output text 2>/dev/null || echo "")

if [ -n "$DOMAIN_ID" ] && [ "$DOMAIN_ID" != "None" ]; then
  ROLE_ARN=$(aws sagemaker describe-domain --region "$REGION" --domain-id "$DOMAIN_ID" \
    --query 'DefaultUserSettings.ExecutionRole' --output text 2>/dev/null || echo "")
  if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "None" ]; then
    ROLE_NAME=$(echo "$ROLE_ARN" | awk -F'/' '{print $NF}')
    echo "      (SageMaker Domain ${DOMAIN_ID} 에서 Execution Role 감지)"
  fi
fi

# (b) Fallback: caller identity 에서 추출
if [ -z "$ROLE_NAME" ]; then
  CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
  ROLE_NAME=$(echo "$CALLER_ARN" | grep -oP 'assumed-role/\K[^/]+' || echo "")
  if [ -n "$ROLE_NAME" ]; then
    ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    echo "      (Caller Identity 에서 Role 감지: $CALLER_ARN)"
  fi
fi

if [ -z "$ROLE_NAME" ]; then
  echo "ERROR: SageMaker Execution Role 을 감지할 수 없습니다."
  echo "       SageMaker Domain 이 존재하는지, 또는 SageMaker 환경에서 실행 중인지 확인하세요."
  exit 1
fi
echo "[3/4] Detected Role          : $ROLE_NAME"
echo "      Role ARN               : $ROLE_ARN"

# ----------------------------------------------------------------------------
# 4) MLflow Tracking Server ARN 자동 감지
# ----------------------------------------------------------------------------
TRACKING_SERVER=$(aws sagemaker list-mlflow-tracking-servers --region "$REGION" \
  --query 'TrackingServerSummaries[0].TrackingServerArn' --output text)
if [ -z "$TRACKING_SERVER" ] || [ "$TRACKING_SERVER" = "None" ]; then
  echo "ERROR: MLflow Tracking Server 를 찾을 수 없습니다. 먼저 Tracking Server 를 생성해주세요."
  exit 1
fi
echo "[4/4] Detected Tracking Srv  : $TRACKING_SERVER"

echo ""
echo "=============================================="
echo " 위 정보로 IAM Policy 를 적용합니다..."
echo "=============================================="

# ----------------------------------------------------------------------------
# 정책 생성 및 적용
# ----------------------------------------------------------------------------
cat > /tmp/mlflow-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sagemaker-mlflow:*",
      "Resource": "${TRACKING_SERVER}"
    }
  ]
}
EOF

if aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name MLflowAccess \
    --policy-document file:///tmp/mlflow-policy.json; then
  echo ""
  echo "SUCCESS: Role '$ROLE_NAME' 에 MLflowAccess 정책이 적용되었습니다."
else
  echo ""
  echo "FAILED: 정책 적용에 실패했습니다. 위 에러 메시지를 확인하세요."
  exit 1
fi

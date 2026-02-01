#!/bin/bash

set -e

# Configurações
CLUSTER_NAME="cluster-bia"
SERVICE_NAME="service-bia"
TASK_FAMILY="task-def-bia"
ECR_REPO="012169730544.dkr.ecr.us-east-1.amazonaws.com/bia"
REGION="us-east-1"

echo "🚀 Iniciando deploy versionado do BIA..."

# Verificar se está em repositório Git
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Erro: Não está em um repositório Git"
    exit 1
fi

# Capturar commit hash
COMMIT_HASH=$(git rev-parse --short HEAD)
IMAGE_TAG="bia-${COMMIT_HASH}"
FULL_IMAGE_URI="${ECR_REPO}:${IMAGE_TAG}"

echo "📝 Commit hash: ${COMMIT_HASH}"
echo "🏷️  Tag da imagem: ${IMAGE_TAG}"

# Verificar se imagem já existe
if aws ecr describe-images --repository-name bia --image-ids imageTag=${IMAGE_TAG} --region ${REGION} > /dev/null 2>&1; then
    echo "⚠️  Imagem ${IMAGE_TAG} já existe no ECR"
    read -p "Deseja continuar mesmo assim? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Deploy cancelado"
        exit 1
    fi
fi

# Login no ECR
echo "🔐 Fazendo login no ECR..."
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_REPO}

# Build da imagem
echo "🔨 Fazendo build da imagem..."
docker build -t ${IMAGE_TAG} .
docker tag ${IMAGE_TAG} ${FULL_IMAGE_URI}

# Push para ECR
echo "📤 Fazendo push para ECR..."
docker push ${FULL_IMAGE_URI}

# Obter task definition atual
echo "📋 Obtendo task definition atual..."
CURRENT_TASK_DEF=$(aws ecs describe-task-definition --task-definition ${TASK_FAMILY} --region ${REGION})

# Criar nova task definition
echo "📝 Criando nova task definition..."
NEW_TASK_DEF=$(echo ${CURRENT_TASK_DEF} | jq --arg IMAGE "${FULL_IMAGE_URI}" '
    .taskDefinition | 
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy) |
    .containerDefinitions[0].image = $IMAGE
')

# Registrar nova task definition
echo "📋 Registrando nova task definition..."
echo ${NEW_TASK_DEF} > /tmp/new-task-def.json
NEW_TASK_ARN=$(aws ecs register-task-definition --region ${REGION} --cli-input-json file:///tmp/new-task-def.json | jq -r '.taskDefinition.taskDefinitionArn')

echo "✅ Nova task definition criada: ${NEW_TASK_ARN}"

# Atualizar service
echo "🔄 Atualizando service..."
aws ecs update-service \
    --cluster ${CLUSTER_NAME} \
    --service ${SERVICE_NAME} \
    --task-definition ${NEW_TASK_ARN} \
    --region ${REGION} > /dev/null

echo "⏳ Aguardando deploy completar..."
aws ecs wait services-stable \
    --cluster ${CLUSTER_NAME} \
    --services ${SERVICE_NAME} \
    --region ${REGION}

echo "🎉 Deploy concluído com sucesso!"
echo "📊 Versão deployada: ${IMAGE_TAG}"
echo "🔗 Task Definition: ${NEW_TASK_ARN}"

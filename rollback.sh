#!/bin/bash

set -e

# Configurações
CLUSTER_NAME="cluster-bia"
SERVICE_NAME="service-bia"
TASK_FAMILY="task-def-bia"
ECR_REPO="012169730544.dkr.ecr.us-east-1.amazonaws.com/bia"
REGION="us-east-1"

echo "🔄 Script de Rollback do BIA"

# Listar imagens disponíveis
echo "📋 Versões disponíveis no ECR:"
IMAGES=$(aws ecr describe-images --repository-name bia --region ${REGION} --query 'sort_by(imageDetails,&imagePushedAt)[*]' --output json)

if [ "$(echo ${IMAGES} | jq length)" -eq 0 ]; then
    echo "❌ Nenhuma imagem encontrada no ECR"
    exit 1
fi

# Mostrar apenas tags que começam com "bia-"
echo ${IMAGES} | jq -r '.[] | select(.imageTags != null) | .imageTags[] | select(startswith("bia-"))' | sort -r | head -10 | nl -v0

echo ""
read -p "Digite o número da versão para rollback (0-9): " VERSION_INDEX

# Obter a tag selecionada
SELECTED_TAG=$(echo ${IMAGES} | jq -r '.[] | select(.imageTags != null) | .imageTags[] | select(startswith("bia-"))' | sort -r | head -10 | sed -n "$((VERSION_INDEX + 1))p")

if [ -z "${SELECTED_TAG}" ]; then
    echo "❌ Versão inválida selecionada"
    exit 1
fi

FULL_IMAGE_URI="${ECR_REPO}:${SELECTED_TAG}"

echo "🎯 Versão selecionada: ${SELECTED_TAG}"
echo "🖼️  Imagem: ${FULL_IMAGE_URI}"

read -p "Confirma o rollback para esta versão? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Rollback cancelado"
    exit 1
fi

# Obter task definition atual
echo "📋 Obtendo task definition atual..."
CURRENT_TASK_DEF=$(aws ecs describe-task-definition --task-definition ${TASK_FAMILY} --region ${REGION})

# Criar nova task definition com imagem do rollback
echo "📝 Criando task definition para rollback..."
NEW_TASK_DEF=$(echo ${CURRENT_TASK_DEF} | jq --arg IMAGE "${FULL_IMAGE_URI}" '
    .taskDefinition | 
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy) |
    .containerDefinitions[0].image = $IMAGE
')

# Registrar nova task definition
echo "📋 Registrando task definition de rollback..."
echo ${NEW_TASK_DEF} > /tmp/rollback-task-def.json
NEW_TASK_ARN=$(aws ecs register-task-definition --region ${REGION} --cli-input-json file:///tmp/rollback-task-def.json | jq -r '.taskDefinition.taskDefinitionArn')

echo "✅ Task definition de rollback criada: ${NEW_TASK_ARN}"

# Atualizar service
echo "🔄 Executando rollback..."
aws ecs update-service \
    --cluster ${CLUSTER_NAME} \
    --service ${SERVICE_NAME} \
    --task-definition ${NEW_TASK_ARN} \
    --region ${REGION} > /dev/null

echo "⏳ Aguardando rollback completar..."
aws ecs wait services-stable \
    --cluster ${CLUSTER_NAME} \
    --services ${SERVICE_NAME} \
    --region ${REGION}

echo "🎉 Rollback concluído com sucesso!"
echo "📊 Versão ativa: ${SELECTED_TAG}"
echo "🔗 Task Definition: ${NEW_TASK_ARN}"

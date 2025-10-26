#!/bin/bash

# 构建未签名 IPA 脚本
# 用法: ./build_unsigned_ipa.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}开始构建未签名 IPA${NC}"
echo -e "${GREEN}======================================${NC}"

# 配置
PROJECT_NAME="ReadApp"
SCHEME="ReadApp"
CONFIGURATION="Release"
BUILD_DIR="./build"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
IPA_DIR="${BUILD_DIR}/ipa"
IPA_NAME="${PROJECT_NAME}_unsigned.ipa"

# 清理旧文件
echo -e "\n${YELLOW}步骤 1/5: 清理旧文件...${NC}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${IPA_DIR}"

# 构建 Archive
echo -e "\n${YELLOW}步骤 2/5: 构建 Archive...${NC}"
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=iOS" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=NO

if [ $? -ne 0 ]; then
    echo -e "${RED}Archive 构建失败！${NC}"
    exit 1
fi

# 创建 Payload 目录
echo -e "\n${YELLOW}步骤 3/5: 创建 Payload 目录...${NC}"
PAYLOAD_DIR="${IPA_DIR}/Payload"
mkdir -p "${PAYLOAD_DIR}"

# 复制 .app 文件
echo -e "\n${YELLOW}步骤 4/5: 复制应用文件...${NC}"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo -e "${RED}找不到 .app 文件: ${APP_PATH}${NC}"
    exit 1
fi

cp -r "${APP_PATH}" "${PAYLOAD_DIR}/"

# 打包成 IPA
echo -e "\n${YELLOW}步骤 5/5: 打包 IPA...${NC}"
cd "${IPA_DIR}"
zip -r "../${IPA_NAME}" Payload
cd - > /dev/null

# 清理临时文件
rm -rf "${IPA_DIR}"

# 完成
if [ -f "${BUILD_DIR}/${IPA_NAME}" ]; then
    IPA_SIZE=$(du -h "${BUILD_DIR}/${IPA_NAME}" | cut -f1)
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}✅ 构建成功！${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "IPA 文件: ${BUILD_DIR}/${IPA_NAME}"
    echo -e "文件大小: ${IPA_SIZE}"
    echo -e "\n${YELLOW}提示:${NC}"
    echo -e "1. 此为未签名的 IPA 文件"
    echo -e "2. 需要使用签名工具（如轻松签、爱思助手等）进行签名后才能安装"
    echo -e "3. 或者在 Xcode 中使用开发者证书签名安装"
else
    echo -e "\n${RED}❌ 构建失败！${NC}"
    exit 1
fi


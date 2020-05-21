#!/bin/bash -u

THIS_DIR=$(cd $(dirname $0); pwd)
PROJECT_DIR=$(cd $THIS_DIR/..; pwd)

# 環境設定ファイルの読み込み
ENV_FILE=$THIS_DIR/env.sh

if [ ! -e $ENV_FILE ]; then
    cat << EOS > $ENV_FILE
# アプリを動かしているEC2のホスト情報
export EC2_HOST=changeme
# EC2_HOSTで指定したサーバーに接続するための秘密鍵のパス
export EC2_PRIVATE_KEY=changeme

# RDSのエンドポイント
export RDS_ENDPOINT=changeme

# ECSのクラスタのARN
export CLUSTER_ARN=changeme
# ECSのタスク名（タスク定義名:Revision）
export TASK_DEFINITION=changeme
# ECSで起動するコンテナを配置するサブネットのID
export SUBNET_ID=changeme
# ECSで起動するコンテナのセキュリティグループID
export SECURITY_GROUP_ID=changeme

# 実行するスレッド数のパターン
export THREAD_PATTERN="1 5 10 50 100"
# 各スレッド数での試行回数
export LOOP_COUNT=5
EOS

    echo $ENV_FILE が存在しなかったので生成しました。
    echo ファイルを開いて変数を設定してください。
    exit 1
fi

source $ENV_FILE

# 対象の決定 (ec2 or ecs)
TARGET=$1

if [ "$TARGET" != "ec2" -a "$TARGET" != "ecs" ]; then
    echo 第一引数は ec2 または ecs を指定してください TARGET=$TARGET
    exit 1
fi

# RDS の IP アドレス解決
RDS_IP_ADDRESS=$(ssh -i $EC2_PRIVATE_KEY ec2-user@$EC2_HOST nslookup $RDS_ENDPOINT | sed -n -r 's/^Address: ([0-9.]+)$/\1/p')

echo RDS_ENDPOINT=$RDS_ENDPOINT
echo RDS_IP_ADDRESS=$RDS_IP_ADDRESS

# 関数定義
function initializeDatabase() {
    cd $PROJECT_DIR
    mvn generate-resources -Ddb.host=$RDS_IP_ADDRESS
}

function startEc2Tomcat() {
    ssh ec2-user@$EC2_HOST \
        -i $EC2_PRIVATE_KEY \
        'source ~/.bash_profile; $TOMCAT_HOME/bin/startup.sh'
}

function runEcsTask() {
    # コンテナの起動して、レスポンスから TASK_ARN を取得
    TASK_ARN=$(aws ecs run-task --cluster $CLUSTER_ARN --task-definition $TASK_DEFINITION --count 1 --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=DISABLED}" | sed -n -r 's/.*"taskArn": "([^"]+)".*/\1/p' | uniq)

    echo TASK_ARN=$TASK_ARN

    # コンテナが RUNNING になるまで待機
    echo コンテナの起動を待機しています...
    aws ecs wait tasks-running --cluster $CLUSTER_ARN --tasks $TASK_ARN

    # コンテナの IP を取得
    ECR_HOST=$(aws ecs describe-tasks --cluster $CLUSTER_ARN --tasks $TASK_ARN | sed -n -r 's/.*"privateIpv4Address": "([0-9.]+)"/\1/p')

    echo ECR_HOST=$ECR_HOST
}

function startApplicationServer() {
    if [ "$TARGET" == "ec2" ]; then
        startEc2Tomcat
    else
        runEcsTask
    fi
}

function runJMeter() {
    local JMETER_REPORT_DIR=$WORK_DIR/reports
    local JMX_FILE=$THIS_DIR/test.jmx

    if [ "$TARGET" = "ec2" ]; then
        local TARGET_HOST=$EC2_HOST
    else
        local TARGET_HOST=$ECR_HOST
    fi

    cd $WORK_DIR

    jmeter.sh -n \
        -t $JMX_FILE \
        -j $WORK_DIR/test.log \
        -e -l $JMETER_REPORT_DIR/test.jtl \
        -o $JMETER_REPORT_DIR \
        -Jthread.number=$THREAD_NUMBER \
        -Jserver.host=$TARGET_HOST
}

function collectEc2Logs() {
    local LOG_ZIP_FILE_NAME=logs_`date "+%Y%m%d_%H%M%S"`.zip

    ssh ec2-user@$EC2_HOST \
        -i $EC2_PRIVATE_KEY \
        "source ~/.bash_profile; zip -j ~/$LOG_ZIP_FILE_NAME ~/logs/* \$TOMCAT_HOME/logs/*"
    
    scp -i $EC2_PRIVATE_KEY \
        ec2-user@$EC2_HOST:/home/ec2-user/$LOG_ZIP_FILE_NAME $WORK_DIR
    
    unzip $WORK_DIR/$LOG_ZIP_FILE_NAME \
        -d $WORK_DIR/logs

    ssh ec2-user@$EC2_HOST \
        -i $EC2_PRIVATE_KEY \
        'source ~/.bash_profile; rm ~/logs/* $TOMCAT_HOME/logs/*'
}

function collectApplicationLogs() {
    if [ "$TARGET" = "ec2" ]; then
        collectEc2Logs
    fi
}

function stopEc2Tomcat() {
    ssh ec2-user@$EC2_HOST \
        -i $EC2_PRIVATE_KEY \
        'source ~/.bash_profile; $TOMCAT_HOME/bin/shutdown.sh'
}

function stopEcsTask() {
    aws ecs stop-task --cluster $CLUSTER_ARN --task $TASK_ARN
}

function stopApplicationServer() {
    if [ "$TARGET" = "ec2" ]; then
        stopEc2Tomcat
    else
        stopEcsTask
    fi
}

# main 処理
echo THREAD_PATTERN=$THREAD_PATTERN
echo LOOP_COUNT=$LOOP_COUNT

OUT_DIR=$THIS_DIR/logs/$TARGET/test_`date "+%Y%m%d_%H%M%S"`
mkdir $OUT_DIR

for THREAD_NUMBER in $THREAD_PATTERN
do
    THREAD_DIR=$OUT_DIR/$THREAD_NUMBER
    mkdir $THREAD_DIR

    for i in `seq 1 $LOOP_COUNT`
    do
        WORK_DIR=$THREAD_DIR/$i
        mkdir $WORK_DIR
        
        STATE="(thread=$THREAD_NUMBER, i=$i)"
        echo ===== Initialize Database $STATE =====
        initializeDatabase

        echo ===== Start Application Server $STATE =====
        startApplicationServer

        echo ===== Run JMeter $STATE =====
        runJMeter

        echo ===== Collect Application Logs $STATE =====
        collectApplicationLogs

        echo ===== Stop Application Server $STATE =====
        stopApplicationServer
    done
done

echo ===== Collect Total Throughput =====
java $THIS_DIR/CollectTotalThroughput.java $OUT_DIR | sort -t $'\t' -k 1,2 -n > $OUT_DIR/total_throughput.txt

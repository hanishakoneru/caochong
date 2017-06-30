#!/usr/bin/env bash

HADOOP_SRC_HOME=/home/hkoneru/Workspace/hadoopDist
SPARK_SRC_HOME=$HOME/Workspace/spark

let N=3

# The hadoop home in the docker containers
HADOOP_HOME=/hadoop

MODE=hadoop

MASTER_VOLUME=/data/disk1/docker1
SLAVE_VOLUMES=('/data/disk1/docker2'
               '/data/disk1/docker3'
               '/data/disk1/docker4'
               '/data/disk2/docker2'
	       '/data/disk2/docker3'
               '/data/disk2/docker4'
               '/data/disk3/docker2'
               '/data/disk3/docker3'
               '/data/disk3/docker4')

function usage() {
    echo "Usage: ./run.sh hadoop|spark [--rebuild] [--nodes=N]"
    echo
    echo "hadoop       Make running mode to hadoop"
    echo "spark        Make running mode to spark"
    echo "--rebuild    Rebuild hadoop if in hadoop mode; else reuild spark"
    echo "--nodes      Specify the number of total nodes"
}

# @Return the hadoop distribution package for deployment
function hadoop_target() {
    echo $(find $HADOOP_SRC_HOME/ -type d -name 'hadoop-*-SNAPSHOT')
}

function build_hadoop() {
    if [[ $REBUILD -eq 1 || "$(docker images -q caochong-hadoop)" == "" ]]; then
        echo "Building Hadoop...."
        #rebuild the base image if not exist
        if [[ "$(docker images -q caochong-base)" == "" ]]; then
            echo "Building Docker...."
            docker build -t caochong-base .
        fi

        mkdir tmp

        # Prepare hadoop packages and configuration files
        # mvn -f $HADOOP_SRC_HOME/pom.xml clean package -DskipTests -Dtar -Pdist -q || exit 1
        HADOOP_TARGET_SNAPSHOT=$(hadoop_target)
        echo $HADOOP_TARGET_SNAPSHOT
        cp -r $HADOOP_TARGET_SNAPSHOT tmp/hadoop
        cp hadoopconf/* tmp/hadoop/etc/hadoop/

        # Generate docker file for hadoop
cat > tmp/Dockerfile << EOF
        FROM caochong-base

        ENV HADOOP_HOME $HADOOP_HOME
        ADD hadoop $HADOOP_HOME
        ENV HADOOP_CONF_DIR /hadoop/etc/hadoop
        ENV HDFS_NAMENODE_USER hdfs
        ENV HDFS_DATANODE_USER hdfs
        ENV HDFS_SECONDARYNAMENODE_USER hdfs
        ENV YARN_NODEMANAGER_USER yarn
        ENV PATH "\$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

        RUN adduser --disabled-password --gecos '' hdfs
        RUN adduser --disabled-password --gecos '' yarn
        RUN chown -R hdfs $HADOOP_HOME
        USER hdfs
        RUN ssh-keygen -t rsa -f ~/.ssh/id_rsa -P '' && \
            cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        USER root
EOF
        echo "Building image for hadoop"
        docker rmi -f caochong-hadoop
        docker build -t caochong-hadoop tmp

        # Cleanup
        rm -rf tmp
    fi
}

# Parse and validatet the command line arguments
function parse_arguments() {
    while [ "$1" != "" ]; do
        PARAM=`echo $1 | awk -F= '{print $1}'`
        VALUE=`echo $1 | awk -F= '{print $2}'`
        case $PARAM in
            -h | --help)
                usage
                exit
                ;;
            --rebuild)
                REBUILD=1
                ;;
            --format)
                FORMAT=1
                ;;
            --nodes)
                N=$VALUE
                ;;
            *)
                echo "ERROR: unknown parameter \"$PARAM\""
                usage
                exit 1
                ;;
        esac
        shift
    done
}
parse_arguments $@

build_hadoop

docker network create caochong 2> /dev/null

# remove the outdated master
echo "Removing outdated master"
echo $(docker ps -a -q -f "name=caochong")
docker rm -f $(docker ps -a -q -f "name=caochong") 2>&1 > /dev/null

# launch master container
echo "Launch master container"
if [[ $FORMAT -eq 1 || $REBUILD -eq 1 ]]; then
   echo "Deleting " ${MASTER_VOLUME}/data
   rm -r ${MASTER_VOLUME}/data
fi
master_id=$(docker run -d -v $MASTER_VOLUME/name:/hadoop-data/name -v $MASTER_VOLUME/data:/hadoop-data/data --net caochong --name caochong-master caochong-$MODE)
echo ${master_id:0:12} > hosts
echo "Master " ${master_id:0:12}
docker exec -t $master_id service ssh restart
docker exec -t $master_id chown -R hdfs /hadoop-data
# docker cp sshConfigTmp ${master_id:0:12}:/root/.ssh/config
# docker exec -it ${master_id:0:12} chown root.root /root/.ssh/config 
for i in $(seq $((N-1)));
do
    if [[ $FORMAT -eq 1 || $REBUILD -eq 1 ]]; then
       echo "Deleting " ${SLAVE_VOLUMES[$((i-1))]}
       rm -r ${SLAVE_VOLUMES[$((i-1))]}
    fi
    container_id=$(docker run -d -v ${SLAVE_VOLUMES[$((i-1))]}/data:/hadoop-data/data --net caochong caochong-$MODE)
    echo "Slave "${container_id:0:12}
    echo ${container_id:0:12} >> hosts  
    # docker exec -it $master_id ssh-copy-id $container_id
    docker exec -t $container_id service ssh restart
    docker exec -t $container_id chown -R hdfs /hadoop-data
done

# Copy the workers file to the master container
docker cp hosts $master_id:$HADOOP_HOME/etc/hadoop/workers
echo "Copied workers"

# Start hdfs and yarn services
if [[ $FORMAT -eq 1 || $REBUILD -eq 1 ]]; then
   docker exec -it -u root $master_id $HADOOP_HOME/bin/hdfs namenode -format
   echo "Formatted Namenode"
fi
docker exec -it $master_id $HADOOP_HOME/sbin/start-dfs.sh
echo "Started dfs"
# echo "Starting yarn"
# docker exec -it $master_id $HADOOP_HOME/sbin/start-yarn.sh

# Connect to the master node
docker exec -it caochong-master /bin/bash

#!/usr/bin/env bash

INDEX=0
N=3
CLUSTER='mycluster'
HADOOP_HOME=/hadoop
VOLUMES=()
NUM_VOLUMES=0

function usage() {
    echo "Usage: ./run.sh --hadoopDir=<path-to-hadoop-home> [--cluster=CLUSTER_NAME] [--nodes=N] [--rebuild] [--format]"
    echo
    echo "--hadoopDir  Path to hadoop home dir"
    echo "--cluster    Name of cluster"
    echo "--nodes      Specify the number of total nodes"
    echo "--rebuild    Rebuild hadoop. Namenode is formatted"
    echo "--format     Format the Namenode"
}

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
            --cluster)
                CLUSTER=$VALUE
                ;;
            --hadoopDir)
                HADOOP_DIR=$VALUE
                ;;
            *)
                echo "ERROR: unknown parameter \"$PARAM\""
                usage
                exit 1
                ;;
        esac
        shift
    done
    if [ "$HADOOP_DIR" == '' ]; then
    	echo "Error: Hadoop Dir needs to be specified"
    	usage
    	exit 1
    fi
}

function read_volumes() {
	while IFS='' read -r line || [[ -n "$line" ]]; do
		VOLUMES[$INDEX]=$line
		INDEX=$((INDEX+1))
	done < DockerVolumes
	NUM_VOLUMES=${#VOLUMES[@]}
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
        echo $HADOOP_DIR
        cp -r $HADOOP_DIR tmp/hadoop
        cp hadoopconf/* tmp/hadoop/etc/hadoop/

        # Generate docker file for hadoop
cat > tmp/Dockerfile << EOF
        FROM caochong-base

        ENV HADOOP_HOME $HADOOP_HOME
        ADD hadoop $HADOOP_HOME
        ENV HADOOP_CONF_DIR /hadoop/etc/hadoop
        ENV HDFS_NAMENODE_USER hdfs
        ENV HDFS_DATANODE_USER hdfs
        ENV HDFS_JOURNALNODE_USER hdfs
        ENV HDFS_ZKFC_USER hdfs
        ENV HDFS_SECONDARYNAMENODE_USER hdfs
        ENV PATH "\$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

        RUN adduser --disabled-password --gecos '' hdfs
        RUN chown -R hdfs $HADOOP_HOME
        USER hdfs
        ENV PATH "\$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"
        RUN ssh-keygen -t rsa -f ~/.ssh/id_rsa -P '' && \
            cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        USER root
EOF
        echo "Building image for hadoop"
        docker rmi -f caochong-hadoop $CLUSTER
        docker build -t caochong-hadoop tmp --tag $CLUSTER

        # Cleanup
        rm -rf tmp
    fi
}

function print_node_info() {
	echo "-----------------------------------"
	echo "Node Info:"
	for i in $(seq $((N)));
	do 
		echo ${NODES[$((i-1))]}
	done
	echo "-----------------------------------"
}

parse_arguments $@
read_volumes
if [ "$NUM_VOLUMES" -lt "$N" ]; then
	echo "Num of volumes configured is less than number of nodes"
	echo "Add more volumes to DockerVolumes file"
	exit 1
fi
build_hadoop

docker network create caochong 2> /dev/null

# remove the old nodes
echo "Removing old nodes from \""$CLUSTER"\" cluster"
OLD_NODES=$(docker ps -a -q -f "name=$CLUSTER")
if [[ "$OLD_NODES" != '' ]]; then
	docker rm -f $OLD_NODES 2>&1 > /dev/null
fi

# remove hosts file if it exists
if [[ -f hosts ]]; then
	rm hosts
fi

NODES=()
INDEX=0
for i in $(seq $((N)));
do
    if [[ $FORMAT -eq 1 || $REBUILD -eq 1 ]]; then
    	if [[  -d "${VOLUMES[$((i-1))]}" ]]; then
    		echo "Deleting data from" ${VOLUMES[$((i-1))]}
    		if [[  -d "${VOLUMES[$((i-1))]}/nn" ]]; then
    			rm -r ${VOLUMES[$((i-1))]}/nn
    		fi
    		if [[  -d "${VOLUMES[$((i-1))]}/dn" ]]; then
    			rm -r ${VOLUMES[$((i-1))]}/dn
    		fi
    		if [[  -d "${VOLUMES[$((i-1))]}/jn" ]]; then
    			rm -r ${VOLUMES[$((i-1))]}/jn
    		fi
    	fi
    fi
    
    port=$((i+9869))
    port_router=$((i+50070))
    
    container_id=$(docker run -d -v ${VOLUMES[$((i-1))]}/nn:/data/nn -v ${VOLUMES[$((i-1))]}/dn:/data/dn -v ${VOLUMES[$((i-1))]}/jn:/data/jn -p 127.0.0.1:$port:9870 -p 127.0.0.1:$port_router:50071 --net caochong --name $CLUSTER-node-$i caochong-hadoop)
    
    echo "Node "$i "=>" ${container_id:0:12}
    NODES[$INDEX]="$CLUSTER"-node-"$i ${container_id:0:12}"
    INDEX=$((INDEX+1))
    
    echo ${container_id:0:12} >> hosts  
    # docker exec -it $master_id_1 ssh-copy-id $container_id
    docker exec -t $container_id service ssh restart
    docker exec -t $container_id chown -R hdfs /data
done

# Copy the workers file to the master container
docker cp hosts $CLUSTER-node-1:$HADOOP_HOME/etc/hadoop/workers
docker cp hosts $CLUSTER-node-3:$HADOOP_HOME/etc/hadoop/workers

echo "----------Starting journalnodes----------"
docker exec -it -u root $CLUSTER-node-3 $HADOOP_HOME/bin/hdfs --daemon start journalnode >> jn1.log
docker exec -it -u root $CLUSTER-node-4 $HADOOP_HOME/bin/hdfs --daemon start journalnode >> jn2.log
docker exec -it -u root $CLUSTER-node-5 $HADOOP_HOME/bin/hdfs --daemon start journalnode >> jn3.log
sleep 5

echo "----------Formatting Namenodes----------"
CLUSTER_ID=CID-$(uuidgen)
docker exec -it -u root $CLUSTER-node-1 $HADOOP_HOME/bin/hdfs namenode -format -clusterId $CLUSTER_ID >> nn1-format.log
docker exec -it -u root $CLUSTER-node-3 $HADOOP_HOME/bin/hdfs namenode -format -clusterId $CLUSTER_ID >> nn3-format.log

echo "----------Start Namenodes----------"
docker exec -it -u root $CLUSTER-node-1 $HADOOP_HOME/bin/hdfs --daemon start namenode >> nn1.log
docker exec -it -u root $CLUSTER-node-3 $HADOOP_HOME/bin/hdfs --daemon start namenode >> nn3.log

echo "----------Bootstraping Standby Namenodes----------"
docker exec -it -u root $CLUSTER-node-2 $HADOOP_HOME/bin/hdfs namenode -bootstrapStandby >> nn2.log
docker exec -it -u root $CLUSTER-node-4 $HADOOP_HOME/bin/hdfs namenode -bootstrapStandby >> nn4.log

echo "----------Starting dfs----------"
docker exec -it $CLUSTER-node-1 $HADOOP_HOME/sbin/start-dfs.sh

echo "----------Transitioning to Active----------"
docker exec -it -u hdfs $CLUSTER-node-1 $HADOOP_HOME/bin/hdfs haadmin -ns ns1 -transitionToActive nn1 --forcemanual
docker exec -it -u hdfs $CLUSTER-node-1 $HADOOP_HOME/bin/hdfs haadmin -ns ns2 -transitionToActive nn3 --forcemanual

print_node_info

docker exec -it -u hdfs $CLUSTER-node-1 /bin/bash


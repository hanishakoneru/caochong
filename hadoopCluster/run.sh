#!/usr/bin/env bash

INDEX=0
N=3
CLUSTER='mycluster'

# HADOOP_HOME for the containers.
HADOOP_HOME=/hadoop

# Volumes read from DockerFile
VOLUMES=()

function usage() {
    echo "Usage: ./run.sh --hadoopDist=<path-to-hadoop-tarball> [--cluster=CLUSTER_NAME] [--nodes=N] [--rebuild] [--format]"
    echo
    echo "--hadoopDist   Path to the hadoop tarball"
    echo "--cluster      Name of cluster"
    echo "--nodes        Specify the number of total nodes"
    echo "--rebuild      Rebuild hadoop. Namenode is formatted"
    echo "--format       Format the Namenode"
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
            --hadoopDist)
                HADOOP_DIST=$VALUE
                ;;
            *)
                echo "ERROR: unknown parameter \"$PARAM\""
                usage
                exit 1
                ;;
        esac
        shift
    done
    if [[ -z "${HADOOP_DIST}" ]]; then
    	echo "Error: Hadoop Distribution Tarball must be specified"
    	usage
    	exit 1
    fi
    if [[ ! -f ${HADOOP_DIST}"" ]]; then
        echo "Error: Specified Hadoop Distribution does not exist: ${HADOOP_DIST}"
        exit 1
    fi
}

function read_volumes() {
    if [[ ! -f DockerVolumes ]]; then
        echo "File DockerVolumes does not exist."
        exit 2
    fi
    local REGEX_COMMENT="^#"
	while IFS='' read -r line || [[ -n "$line" ]]; do
        if ! [[ ${line} =~ ${REGEX_COMMENT} ]]; then
    		VOLUMES[${INDEX}]=${line}
    		INDEX=$((INDEX+1))
        fi
	done < DockerVolumes
}

function build_hadoop() {
    if [[ $REBUILD -eq 1 || "$(docker images -q caochong-hadoop)" == "" ]]; then
        echo "Building Hadoop...."
        #rebuild the base image if not exist
        if [[ "$(docker images -q caochong-base)" == "" ]]; then
            echo "Building Docker...."
            docker build -t caochong-base .
        fi

        rm -rf tmp/hadoop/
        mkdir -p tmp/hadoop/

        # Prepare hadoop packages and configuration files
        echo "Extracting hadoop tarball: ${HADOOP_DIST}"
        tar --strip 1 -C tmp/hadoop/ -xf ${HADOOP_DIST}
        cp -r hadoopconf/* tmp/hadoop/etc/hadoop

        # Generate docker file for hadoop
cat > tmp/Dockerfile << EOF
        FROM caochong-base

        ENV HADOOP_HOME $HADOOP_HOME
        ADD hadoop $HADOOP_HOME
        ENV HADOOP_CONF_DIR=/hadoop/etc/hadoop \
            HADOOP_NAMENODE_USER=hdfs \
            HADOOP_DATANODE_USER=hdfs \
            HDFS_DATANODE_USER=hdfs \
            HDFS_JOURNALNODE_USER=hdfs \
            HDFS_NAMENODE_USER=hdfs \
            HDFS_SECONDARYNAMENODE_USER=hdfs \
            HDFS_ZKFC_USER=hdfs \
            PATH="\$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

        RUN adduser --disabled-password --gecos '' hdfs && \
            chown -R hdfs $HADOOP_HOME
        USER hdfs
        ENV PATH "\$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"
        RUN mkdir -p ~/.ssh && \
            chmod 700 ~/.ssh && \
            ssh-keygen -t rsa -f ~/.ssh/id_rsa -P '' && \
            cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && \
            echo 'Host *' >> ~/.ssh/config && \
            echo '  StrictHostKeyChecking no' >> ~/.ssh/config && \
            echo '  UserKnownHostsFile=/dev/null' >> ~/.ssh/config && \
            echo >> ~/.ssh/config
        USER root
        RUN mkdir -p ~/.ssh && \
            chmod 700 ~/.ssh && \
            echo 'Host *' >> ~/.ssh/config && \
            echo '  StrictHostKeyChecking no' >> ~/.ssh/config && \
            echo '  UserKnownHostsFile=/dev/null' >> ~/.ssh/config && \
            echo >> ~/.ssh/config

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
if [[ "${#VOLUMES[@]}" -lt "$N" ]]; then
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
docker cp hosts $CLUSTER-node-1:$HADOOP_HOME/etc/hadoop/slaves

if [[ "${FORMAT}" = "1" ]]; then
    echo "----------Formatting the Namenode----------"
    docker exec -it -u hdfs $CLUSTER-node-1 $HADOOP_HOME/bin/hdfs namenode -format

    echo "----------Starting dfs----------"
    docker exec -it -u hdfs $CLUSTER-node-1 $HADOOP_HOME/sbin/start-dfs.sh
fi

print_node_info

# Launch a shell on the first cluster node.
docker exec -it -u hdfs $CLUSTER-node-1 /bin/bash


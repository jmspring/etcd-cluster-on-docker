#!/bin/bash
# This bash script attempts to establish exclusive control over
# a subdirectory to FS_PATH.  This is done by first looking for
# a missing directory and then creating it and generating a 
# lockfile.  Failing that, the next step is that it will try
# existing directories in the range of 0..NODE_COUNT, exclusive.
[ -z "$FS_PATH" ] && echo "Need to set FS_PATH" && exit 1;
[ -z "$NODE_COUNT" ] && echo "Need to set NODE_COUNT" && exit 1;

APP_NAME="etcd-test"
LOCKFILE="$APP_NAME.lock"
CONTAINER_IP_FILE="$APP_NAME.node_ip"
CONTAINER_ID_FILE="$APP_NAME.node_id"
AUTHORITATIVE_ID="0"

ip a

if [ ! -d "$FS_PATH" ]; then
    mkdir -p "$FS_PATH"
fi

launch_etcd() {
    local IP=$1
    local ID=$2
    local DATA_DIR=$3
    local CLUSTER_STATE=$4
    local INITIAL_CLUSTER=$5

    if [ -z "$INITIAL_CLUSTER" ]; then    
        INITIAL_CLUSTER="$APP_NAME-$ID=http://$IP:2380"
    else
        INITIAL_CLUSTER="$INITIAL_CLUSTER,$APP_NAME-$ID=http://$IP:2380"
    fi

    (
        /bin/etcd -data-dir="$DATA_DIR" -initial-cluster-state $CLUSTER_STATE -listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 -advertise-client-urls http://$IP:2379  -listen-peer-urls http://$IP:2380,http://$IP:7001 -initial-advertise-peer-urls http://$MY_IP:2380 -name "$APP_NAME-$ID" -initial-cluster "$INITIAL_CLUSTER"
    ) &
    
    local PID=""
    for f in {1..5}; do
    echo ps auxwww | grep $MY_IP | grep etcd | grep -v grep | awk '{print $1}'
        local PROCESS_PID=`ps auxwww | grep $MY_IP | grep etcd | grep -v grep | awk '{print $1}'`
        if [ $? -eq 0 ]; then
            PID="$PROCESS_PID"
            break
        else
            sleep 1
        fi
    done
    
    ETCD_PID=$PID
}

start_app() {
    if [ -z $1 ]; then
        echo "Directory must be specified."
        return 1
    elif [ -z $2 ]; then
        echo "Node ID must be specified."
        return 1
    fi

    DATADIR=$1
    ID=$2
    WORKINGDIR="$DATADIR/$ID"
    APP_DATA_DIR="$WORKINGDIR/$APP_NAME/data"
    CONTAINER_ID_FILE_PATH="$WORKINGDIR/$CONTAINER_ID_FILE"

    if [ ! -d "$DATADIR" ]; then
        mkdir -p "$DATADIR"
    fi

    MY_IP=`ip -4 addr show scope global dev ethwe | grep inet | awk '{print $2}' | cut -d / -f 1`
    PEER_IPS=`drill $APP_NAME.weave.local | grep $APP_NAME | grep -v "\;\;" | awk '{print $5}' | grep -v $MY_IP`
    CONTAINER_ID=""
    if [ -e "$CONTAINER_ID_FILE_PATH" ]; then
        CONTAINER_ID=`cat $CONTAINER_ID_FILE_PATH`
    fi
    
    if [ -z "$PEER_IPS" ]; then
        if [ ! -z "$CONTAINER_ID" ]; then
            rm "$CONTAINER_ID_FILE_PATH"
            CONTAINER_ID=""
        fi
        
        if [ "$ID" -eq "$AUTHORITATIVE_ID" ]; then
            echo "Launching as master/initial node."
            ETCD_PID=""
            launch_etcd "$MY_IP" "$ID" "$APP_DATA_DIR" "new"
        else
            echo "No seed node running.  Exiting."
            sleep 180
            exit 1
        fi
    else
        #  see if peers have already formed a cluster
        CLUSTER=""
        RUNNING_PEER_IPS=""
        for peer in $PEER_IPS; do
            # attempt to see if client port is open
            nc -w 1 $peer 2379
            if [ $? -eq 0 ]; then
                NAME=`/bin/etcdctl --endpoint=http://$peer:2379 member list | grep "$peer" | awk '{print $2}' | sed s/name=//`
                if [ $? -eq 0 ]; then
                    RUNNING_PEER_IPS="$RUNNING_PEER_IPS $peer"
                    if [ ! -z "$NAME" ]; then
                        if [ -z "$CLUSTER" ]; then
                            CLUSTER="$NAME=http://$peer:2380"
                        else
                            CLUSTER="$CLUSTER,$NAME=http://$peer:2380"
                        fi
                    fi
                fi
            fi
        done
        
        if [ -z "$CLUSTER" ]; then
            if [ "$ID" -eq "$AUTHORITATIVE_ID" ]; then
                echo "Launching as master/initial node, despite other containers being online."
                ETCD_PID=""
                launch_etcd "$MY_IP" "$ID" "$APP_DATA_DIR" "new"
            else
                echo "No seed node running.  Exiting."
                sleep 2
                exit 1
            fi            
        else
            for peer in $RUNNING_PEER_IPS; do
                nc -w 1 $peer 2379
                if [ $? -eq 1 ]; then
                    echo "A known peer went down.  Bad state.  Exiting..."
                    exit 1
                else
                    ADD_PEER=1
                    if [ ! -z "$CONTAINER_ID" ]; then
                        KNOWN_ID=`/bin/etcdctl --endpoint=http://$peer:2379 member list | grep "$CONTAINER_ID" | awk '{print $1}' | sed 's/\://'`
                        if [ ! -z "$KNOWN_ID" ]; then
                            # update the cluster with information of the node taking over, fo shizzle
                            echo "Updating node in the cluster.  ID: $KNOWN_ID, IP: $MY_IP"
                            /bin/etcdctl --endpoint=http://$peer:2379 member update $KNOWN_ID http://$MY_IP:2380
                            if [ $? -eq 1 ]; then
                                echo "Error updating member in cluster.  ID: $KNOWN_ID, IP: $MY_IP  Exiting..."
                                exit 1
                            fi
                            ADD_PEER=0
                        fi
                    fi
                    
                    if [ "$ADD_PEER" -eq 1 ]; then 
                        # add the peer to the cluster
                        echo "Adding node to the cluster.  IP: $MY_IP"
                        /bin/etcdctl --endpoint=http://$peer:2379 member add "$APP_NAME-$ID" http://$MY_IP:2380
                        if [ $? -eq 1 ]; then
                            echo "Error adding member to cluster.  IP: $MY_IP  Exiting..."
                            exit 1
                        fi
                    fi
                fi                  
                break
            done
        fi

        ETCD_PID=""
        echo "Launching etcd into an existing cluster.  IP: $MY_IP.  Cluster: $CLUSTER"
        launch_etcd "$MY_IP" "$ID" "$APP_DATA_DIR" "existing" "$CLUSTER"
    fi
    
    # wait for etcd to be available
    ETCD_UP=0
    for f in {1..10}; do
        sleep 1
        nc -w 1 localhost 2379
        if [ $? -eq 0 ]; then
            ETCD_UP=1
            break
        fi
    done
    
    if [ "$ETCD_UP" -eq 0 ]; then
        echo "etcd did not come up...exiting..."
        exit 1
    fi

    # get container id
    CONTAINER_ID=`/bin/etcdctl member list | grep "$MY_IP" | awk '{print $1}' | sed 's/\://'`
    echo "$CONTAINER_ID" > "$CONTAINER_ID_FILE_PATH"
    
    # loop while PID exists
    while true; do
        ps -A -o pid | grep "$ETCD_PID" > /dev/null
        if [ $? -ne 0 ]; then
            # process stopped, exit
            break
        else
            sleep 5
        fi
    done
    
    echo "Exiting."
    exit 1
}


lock_data_dir() {
    if [ -z $1 ]; then
        echo "Directory must be specified."
        return 1
    elif [ -z $2 ]; then
        echo "Node ID must be specified."
        return 1
    fi
    
    DATADIR=$1
    ID=$2
    WORKINGDIR="$DATADIR/$ID"
    cd $1
    if [ $? -ne 0 ]; then
        echo "Unable to change into directory $WORKINGDIR"
        return 1
    fi
    
    echo "Attempting to lock: $WORKINGDIR/$LOCKFILE"
    exec 200>> "$WORKINGDIR/$LOCKFILE"
    flock -n 200
    if [ $? -ne 0 ]; then
        echo "Unable to lock."
        exec 200>&-
        return 1;
    else
        date 1>&200
        echo "Lock acquired.  Starting application."
        start_app "$FS_PATH" "$ID"
    fi
}

# check for missing directory
typeset -i i END
let END=$NODE_COUNT i=0 1
while ((i<END)); do
    DATADIR="$FS_PATH/$i"
    echo "Attempting $DATADIR"
    if [ ! -d "$DATADIR" ]; then
        r=`mkdir "$DATADIR"`
        if [ $? -eq 0 ]; then
            lock_data_dir "$FS_PATH" "$i"
            if [ $? -ne 0 ]; then
                echo "Error locking directory."
            fi
        else
            if [ ! -d "$DATADIR" ]; then
                echo "Unable to create directory.  System error."
                exit 1
            else
                echo "Another process already created directory."
            fi
        fi
    else
        echo "Directory already taken."
    fi
    let i++ 1
done

# if no directory missing, attempt to grab a currently unused but
# setup directory.
let i=0 1
while ((i<END)); do
    DATADIR="$FS_PATH/$i"
    echo "Attempting $DATADIR"
    if [ ! -d "$DATADIR" ]; then
        echo "$DATADIR does not exist.  It should."
        exit 1
    fi
    
    lock_data_dir "$FS_PATH" "$i"
    if [ $? -ne 0 ]; then
        echo "Unable to lock directory."
    fi
    
    let i++ 1
done

echo "Attempt to lock a directory failed.  Exiting."

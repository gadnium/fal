#!/bin/bash -x

# How wide we should process
# (This is used as threads per db instance)
# Can be overridden via script params
THREADS=16

# The value for DATA_LENGTH+INDEX_LENGTH (table size) in bytes over which we dump/import a table in parallel
SPLIT_THRESHOLD=5000000000

# Binaries & connection strings for source and target database instances
MYSQL_SRC_HOST="127.0.0.1"
MYSQL_SRC_PORT="3402"
MYSQL_SRC_USER="runbook"
MYSQL_SRC="-h${MYSQL_SRC_HOST} -P${MYSQL_SRC_PORT} -u${MYSQL_SRC_USER}"
MYSQL_SRC_CLIENT="/glide/mysql/5.5.36/bin/mysql"
MYSQL_SRC_DUMP="/glide/mysql/5.5.36/bin/mysqldump"

MYSQL_TGT_HOST="127.0.0.1"
MYSQL_TGT_PORT="3401"
MYSQL_TGT_USER="runbook"
MYSQL_TGT="-h${MYSQL_TGT_HOST} -P${MYSQL_TGT_PORT} -u${MYSQL_TGT_USER}"
MYSQL_TGT_CLIENT="/glide/mysql/5.6.16/bin/mysql"

# Options for dumping schema & data
MYSCHEMA="-q --no-data --quote-names --allow-keywords --add-drop-table --single-transaction "
MYDATA="-q --no-create-info --quote-names --allow-keywords --extended-insert --skip-add-locks --skip-disable-keys --single-transaction --no-autocommit "

# Be strict
set -e
set -u
export PS4='+$BASH_SOURCE:$LINENO:${FUNCNAME:-main}(): '

# Variable initialization
CATALOG=""
DESTINATION=""
MASTER=""
REPLSTOP=""
MAKETGTSLAVE=false
# Queues
Q_TABLES_TO_CKSUM=()
Q_TABLES_TO_CKSUM_TGT=()

## Capture arguments
MYARGS=$@

while getopts c:t:d:mrf option; do
    case "$option" in
        c) CATALOG=$OPTARG;;
        t) THREADS=$OPTARG;;
        d) DESTINATION=$OPTARG;;
        m) MASTER="--master-data=2";;
        r) REPLSTOP=1;;
        f) MAKETGTSLAVE=true;;
    esac
done

# Usage
[ -z "$CATALOG" ] && { echo "
Usage: 
  $0 <options>
  
        Required:
                -c = Catalog Name 
        Option:
                -t = Number of threads
                -d = Alternate database target for import
                -m = Specify if Master Data is desired.
                -r = Stop Replication
                -f = Finish the job. Make the target a slave of the source.

"; exit 1; }

if [ -z "${DESTINATION}" ]; then
    DESTINATION=${CATALOG}
fi

if [ -n "${MASTER}" ]; then
   MYSCHEMA="${MYSCHEMA} ${MASTER} "
fi

# Queue management functions
function q_pop { eval "${1}=(${1[@]:0:$((${#1[@]}-1))})"; }
function q_shift { eval "${1}=(\"\${$1[@]:1}\")"; }
function q_unshift { eval "${1}=($2 "${1[@]}")"; }
function q_push { eval "${1}+=(\"$2\")"; }
function del_q_idx { eval "${1}=(\${$1[@]:0:$2} \${$1[@]:$(($2 + 1))})"; }
function q_del {
    local c i v
    eval "c=\${#$1[@]}"
    for (( i=0; i<$c; i++ )); do
        eval "v=\${$1[$i]}"
        if [ "$2" = "$v" ]; then
            break
        fi
    done
    del_q_idx "$1" "$i"
}

# Logging...
LOG="progress-import-$(date "+%Y%m%d%H%M%S").log"
exec 3>&1 1>>${LOG} 2>&1
# Only write trace output to console
BASH_XTRACEFD=3
function log {
    echo [$(date "+%Y-%m-%d %H:%M:%S")] "$1" | tee /dev/fd/3
}

if $MAKETGTSLAVE && [ "$CATALOG" != "$DESTINATION" ]; then
    log "Can't make target a slave if name of target catalog doesn't match source catalog! Exiting so intended action can be rectified..."
    exit
fi

# A function to wait for available database threads on the target
function waitForThreads {
    set +e
    RT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -e "SHOW PROCESSLIST" | grep -c $DESTINATION)
    while [ -n "$RT" ] && [ "$RT" -ge "${THREADS}" ]; do
        sleep 1
        RT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -e "SHOW PROCESSLIST" | grep -c $DESTINATION)
    done
    set -e
}

# A function to update the value of threads working specifically on converting tables to InnoDB
CUR_INNODB_THREADS=0
function updCurrentAlterThreadCount {
    set +e
    CUR_INNODB_THREADS=$($MYSQL_TGT_CLIENT $MYSQL_TGT -e "SHOW PROCESSLIST" | grep -c 'ALTER TABLE.*InnoDB')
    set -e
}

# A function to restart the target db
function restartTargetDB {
    local INIT_SCRIPT_TGT="/etc/init.d/"$(basename ${MYSQL_TGT_SOCK} .sock)
    if [ ! -f "$INIT_SCRIPT_TGT" ] || [ ! -x "$INIT_SCRIPT_TGT" ]; then
        log "Couldn't resolve init script to restart target db"
    else
        log "Restarting target db..."
        $INIT_SCRIPT_TGT stop
        sleep 1
        $INIT_SCRIPT_TGT start
    fi
}

# Signal handlers
function handleINT {
    log "Caught INT signal. Cleaning up..."
    set +e
    kill $(jobs -p)
    sleep 2
    $MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW PROCESSLIST" | awk '/'"${DESTINATION}"'/{print "kill "$1";"}' | $MYSQL_TGT_CLIENT $MYSQL_TGT
    exit
}
function handleEXIT {
    rm -f "$SQLFILE"
    log "Exiting..."
    exit
}
trap handleINT INT
trap handleEXIT EXIT



# A temp file for dump/import of schema
SQLFILE=$(mktemp /glide/tmp/mysql-upg.XXXXXXXXXX)



# Check that we're running on the same host as the target
MYSQL_TGT_SOCK=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SELECT @@socket")
if [ ! -S "$MYSQL_TGT_SOCK" ]; then
    log "This script must run on same host as target database! Exiting..."
    exit
fi

# Check sanity of our SPLIT_THRESHOLD vs. single buffer pool instance size
eval $($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW VARIABLES LIKE 'inno%'" | egrep "innodb.*(r_pool_(size|instances)|doublewrite|io_threads)" | tr '[a-z]' '[A-Z]' | sed -e 's@\s\+@=@')
if [ -n "$INNODB_BUFFER_POOL_SIZE" ] && [ -n "$INNODB_BUFFER_POOL_INSTANCES" ]; then
    SUGGESTED_SPLIT=$(( $INNODB_BUFFER_POOL_SIZE / $INNODB_BUFFER_POOL_INSTANCES ))
    SUGGESTED_SPLIT=$(( $SUGGESTED_SPLIT - 10000000 ))
    if [ "$SPLIT_THRESHOLD" -gt "$SUGGESTED_SPLIT" ]; then
        log "Split threshold of $SPLIT_THRESHOLD changed to $SUGGESTED_SPLIT (will fit in a single buffer pool instance)"
        SPLIT_THRESHOLD=$SUGGESTED_SPLIT
    fi
fi

# Warn if InnoDB doublewrite is ON
if [ -n "$INNODB_DOUBLEWRITE" ] && [ "$INNODB_DOUBLEWRITE" == "ON" ]; then
    log "TARGET DB HAS INNODB_DOUBLEWRITE ENABLED!!! (This makes it take a lot longer...)"
    log "Disable this manually before starting this script to rectify"
    sleep 5
fi

# Check for and attempt to add replication filter for percona database so we don't replicate checksumming queries (this script will determine differences)
DATADIR_TGT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SELECT @@datadir")
CHECKSUM_FILTER=$(find ${DATADIR_TGT}/.. -type f -name "*cnf" -exec grep -c 'replicate-wild-ignore.*percona' "{}" \; | sort -n | tail -1)
if $MAKETGTSLAVE && [ -n "$MASTER" ] && [ "$CHECKSUM_FILTER" -lt "1" ]; then
    log "Attempting to rectify missing checksum filter..."
    CNF_FILE=$(find ${DATADIR_TGT}/.. -type f -name "*cnf" -exec grep -H -m1 'replicate-ignore-table' "{}" \; | sed -e 's/:.*//')
    if [ -f "$CNF_FILE" ]; then
        sed -i -e '0,/replicate-ignore-table/ {/replicate-ignore-table/i\
replicate-wild-ignore-table = percona.%
        }' "$CNF_FILE"
        CHECKSUM_FILTER=$(find ${DATADIR_TGT}/.. -type f -name "*cnf" -exec grep -c 'replicate-wild-ignore.*percona' "{}" \; | sort -n | tail -1)
        if [ "$CHECKSUM_FILTER" -ge "1" ]; then
            log "Added replication filter for percona db. Restarting target database..."
            restartTargetDB
            sleep 1
        fi
    else
        log "Target does not have checksum replication filter configured!"
        log "Checksum queries will flow from source to target when hooked up!"
        sleep 5
    fi
fi

# Reduce the number of InnoDB threads to the most sane value
INNODB_IO_THREADS=$THREADS
if [ -n "$INNODB_READ_IO_THREADS" ] && [ "$INNODB_READ_IO_THREADS" -lt "$THREADS" ]; then
    INNODB_IO_THREADS=$INNODB_READ_IO_THREADS
fi
if [ -n "$INNODB_WRITE_IO_THREADS" ] && [ "$INNODB_WRITE_IO_THREADS" -lt "$INNODB_IO_THREADS" ]; then
    INNODB_IO_THREADS=$INNODB_WRITE_IO_THREADS
fi
log "Running with $INNODB_IO_THREADS InnoDB conversion threads..."



# This function is called during export/import of tables under SPLIT_THRESHOLD bytes in size.
# The purpose is to continue the process of converting tables to InnoDB after conversion of larger
# partitioned tables has finished. Otherwise we can have a large timeframe in which only MyISAM
# imports happen until the table list is finished and wholesale InnoDB conversion starts afterward.
# The nice thing is that this will start with the largest tables first.
function checkInnodbConversion {
    updCurrentAlterThreadCount
    if [ -n "$CUR_INNODB_THREADS" ] && [ "$CUR_INNODB_THREADS" -lt "$INNODB_IO_THREADS" ]; then
        AVAILABLE_INNODB_THREADS=$(( $INNODB_IO_THREADS - $CUR_INNODB_THREADS ))
        while read CONVTBL; do
            set +e
            CONV_COUNT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW PROCESSLIST" | grep -c "ALTER TABLE ${DESTINATION}.${CONVTBL}")
            set -e
            if [ "$CONV_COUNT" -eq "0" ]; then
                SEC=$(( $(date +%s) - $TS_START ))
                log "Converting ${CONVTBL}... (${SEC}s elapsed)"
                # Conversion statements for partitioned tables have already been started. Don't worry about table structure here.
                $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION -e "SET SESSION tx_isolation='READ-UNCOMMITTED';SET sql_log_bin = 0;SET unique_checks=0;ALTER TABLE ${DESTINATION}.${CONVTBL} ENGINE=InnoDB" &
                (( AVAILABLE_INNODB_THREADS-- ))
                if [ "$AVAILABLE_INNODB_THREADS" -le "0" ]; then
                    break;
                fi
            fi
        done < <($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$DESTINATION' AND ENGINE='MyISAM' AND TABLE_ROWS > 0 AND UPDATE_TIME < DATE_SUB(NOW(), INTERVAL 10 MINUTE) ORDER BY DATA_LENGTH DESC")
    fi
}


# To correct for errors (like subshells that exit with error and can't be caught resulting in incomplete data transfer)
# We use the Percona Tools to run checksums on source and target. When these are done and all tables are transferred,
# we can use pt-table-sync after replication is hooked up to ensure a good copy.
function processChecksumQueues {
    SRC_THREAD_COUNT=$($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | awk '{print $2}')
    while [ "${#Q_TABLES_TO_CKSUM[@]}" -gt "0" ] && [ "$SRC_THREAD_COUNT" -lt "$THREADS" ]; do
        for (( i = 0 ; i < ${#Q_TABLES_TO_CKSUM[@]} ; i++ )); do
            if [ "$SRC_THREAD_COUNT" -ge "$THREADS" ]; then
                break
            fi
            # Make sure it's not still dumping on the source db
            set +e
            DUMP_COUNT=$($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SHOW PROCESSLIST" | grep -c "${CATALOG}.${Q_TABLES_TO_CKSUM[$i]}")
            set -e
            if [ "$DUMP_COUNT" -eq "0" ]; then
                log "Starting checksum of ${CATALOG}.${Q_TABLES_TO_CKSUM[$i]} on source..."
                pt-table-checksum -q -q --no-version-check --recursion-method=none --chunk-size=10000 --databases=${CATALOG} --host=${MYSQL_SRC_HOST} --port=${MYSQL_SRC_PORT} --user=${MYSQL_SRC_USER} --tables=${CATALOG}.${Q_TABLES_TO_CKSUM[$i]} &
                q_push Q_TABLES_TO_CKSUM_TGT ${Q_TABLES_TO_CKSUM[$i]}
                q_del Q_TABLES_TO_CKSUM ${Q_TABLES_TO_CKSUM[$i]}
            fi
            SRC_THREAD_COUNT=$($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | awk '{print $2}')
        done
    done
    TGT_THREAD_COUNT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | awk '{print $2}')
    while [ "${#Q_TABLES_TO_CKSUM_TGT[@]}" -gt "0" ] && [ "$TGT_THREAD_COUNT" -lt "$THREADS" ]; do
        for (( i = 0 ; i < ${#Q_TABLES_TO_CKSUM_TGT[@]} ; i++ )); do
            if [ "$TGT_THREAD_COUNT" -ge "$THREADS" ]; then
                break
            fi
            # Make sure it's not still importing/altering on the target db
            set +e
            ALTER_COUNT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW PROCESSLIST" | grep -c "${DESTINATION}.${Q_TABLES_TO_CKSUM_TGT[$i]}")
            set -e
            if [ "$ALTER_COUNT" -eq "0" ]; then
                log "Starting checksum of ${DESTINATION}.${Q_TABLES_TO_CKSUM_TGT[$i]} on target..."
                pt-table-checksum -q -q --no-version-check --recursion-method=none --chunk-size=10000 --databases=${DESTINATION} --host=${MYSQL_TGT_HOST} --port=${MYSQL_TGT_PORT} --user=${MYSQL_TGT_USER} --tables=${DESTINATION}.${Q_TABLES_TO_CKSUM_TGT[$i]} &
                q_del Q_TABLES_TO_CKSUM_TGT ${Q_TABLES_TO_CKSUM_TGT[$i]}
            else
                break 2
            fi
            TGT_THREAD_COUNT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | awk '{print $2}')
        done
    done
}


#######################################
## THE FUN STARTS HERE
#######################################

# Store the time we actually start working
TS_START=$(date +%s)

if [ -n "${REPLSTOP}" ]; then
   log "Stopping replication on source..."
   $MYSQL_SRC_CLIENT $MYSQL_SRC -e "STOP SLAVE;"
fi

# Start with dumping the db schema and importing to target
log "Dumping schema for $CATALOG..."
echo "CREATE DATABASE IF NOT EXISTS $DESTINATION; USE $DESTINATION;" >> "$SQLFILE"
$MYSQL_SRC_DUMP $MYSQL_SRC $MYSCHEMA $CATALOG >> "$SQLFILE"
SEC=$(( $(date +%s) - $TS_START ))
log "Importing schema for $DESTINATION... (${SEC}s elapsed)"
# We want to fail if this fails, so no -f
$MYSQL_TGT_CLIENT $MYSQL_TGT < "$SQLFILE"
# Capture master info if desired
if [ -n "$MASTER" ]; then
    eval $(fgrep -m1 'CHANGE MASTER TO' "$SQLFILE" | sed -e 's/.* TO //;s/MASTER/SRC_MASTER/g;s/[,;]//g')
    if [ -n "$SRC_MASTER_LOG_FILE" ] && [ -n "$SRC_MASTER_LOG_POS" ]; then
        log "Captured master log file ${SRC_MASTER_LOG_FILE} and position ${SRC_MASTER_LOG_POS}..."
    else
        log "Failed to capture master status!!!"
        exit
    fi
fi
# Reset tempfile
>"$SQLFILE"



# Alter target tables that will have data to MyISAM for quicker import
# We don't care about a conversion failure of specific tables. Tables that won't convert will just be imported as InnoDB.
SEC=$(( $(date +%s) - $TS_START ))
log "Altering tables with data for quicker import... (${SEC}s elapsed)"
echo "SET sql_log_bin = 0;" >> "$SQLFILE"
COUNTER=0
while read TABLE; do
    echo "ALTER TABLE ${DESTINATION}.${TABLE} ENGINE=MyISAM, DISABLE KEYS;" >> "$SQLFILE"
    COUNTER=$(( $COUNTER + 1 ))
done < <($MYSQL_SRC_CLIENT $MYSQL_SRC -BN -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$CATALOG' AND TABLE_ROWS > 0")
TABLE_COUNT=$COUNTER
# -f flag added here. We don't care that much if one of the conversions fail - well maybe if it's a big table, but not solving that case now
$MYSQL_TGT_CLIENT $MYSQL_TGT -f $DESTINATION < "$SQLFILE"
>"$SQLFILE"


SLEEP_BEFORE_CONVERSION=10
LAST_CONVERSION_START=0


# Now for the good stuff...
SEC=$(( $(date +%s) - $TS_START ))
log "Dump/Import $TABLE_COUNT tables in parallel using $THREADS threads... (${SEC}s elapsed)"


# Process source tables with rows > 0 in order of descending size
INDEX=1
while read TABLE; do
    TABLE_SIZE=$($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SELECT DATA_LENGTH+INDEX_LENGTH AS SIZE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$CATALOG' AND TABLE_NAME='$TABLE'")
    set +e
    PK_COUNT=$($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe " SHOW CREATE TABLE $TABLE\G" $CATALOG | grep -c 'PRIMARY KEY.*sys_id')
    set -e
    if [ "$TABLE_SIZE" -ge "$SPLIT_THRESHOLD" ] && [ "$PK_COUNT" -ge "1" ]; then
        $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION <<-SQL
        SET sql_log_bin = 0;
        ALTER TABLE ${DESTINATION}.${TABLE}
        DISABLE KEYS
        PARTITION BY RANGE COLUMNS(sys_id) (
            PARTITION p0 VALUES LESS THAN ('1'),
            PARTITION p1 VALUES LESS THAN ('2'),
            PARTITION p2 VALUES LESS THAN ('3'),
            PARTITION p3 VALUES LESS THAN ('4'),
            PARTITION p4 VALUES LESS THAN ('5'),
            PARTITION p5 VALUES LESS THAN ('6'),
            PARTITION p6 VALUES LESS THAN ('7'),
            PARTITION p7 VALUES LESS THAN ('8'),
            PARTITION p8 VALUES LESS THAN ('9'),
            PARTITION p9 VALUES LESS THAN ('A'),
            PARTITION pA VALUES LESS THAN ('B'),
            PARTITION pB VALUES LESS THAN ('C'),
            PARTITION pC VALUES LESS THAN ('D'),
            PARTITION pD VALUES LESS THAN ('E'),
            PARTITION pE VALUES LESS THAN ('F'),
            PARTITION pF VALUES LESS THAN (MAXVALUE)
        );
SQL
        for ROUND in $(printf "%x " $(seq -f %1.f 0 15)); do
            SEC=$(( $(date +%s) - $TS_START ))
            log "Dumping ${TABLE}... (${INDEX}/${TABLE_COUNT}, round $ROUND, ${SEC}s elapsed)"
            ( $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION < <(
                echo "SET SESSION tx_isolation='READ-UNCOMMITTED';SET sql_log_bin = 0;"
                $MYSQL_SRC_DUMP $MYSQL_SRC --where "sys_id LIKE '${ROUND}%'" $MYDATA $CATALOG $TABLE | \
                sed -e "s/INSERT INTO ${TABLE}/INSERT INTO ${TABLE} PARTITION (p${ROUND})/"
            ) ) &
            waitForThreads
        done
        SEC=$(( $(date +%s) - $TS_START ))
        log "Converting ${TABLE}... (${SEC}s elapsed)"
        # This should lock until all running ROUNDs are done
        sleep $SLEEP_BEFORE_CONVERSION && $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION -e "SET SESSION tx_isolation='READ-UNCOMMITTED';SET sql_log_bin = 0;SET unique_checks=0;ALTER TABLE ${DESTINATION}.${TABLE} ENGINE=InnoDB REMOVE PARTITIONING" &
        LAST_CONVERSION_START=$(date +%s)
        # JW-08/21/14: no point in calling waitForThreads here since the sleep will still be running when checked 
    else
        SEC=$(( $(date +%s) - $TS_START ))
        log "Dumping ${TABLE}... (${INDEX}/${TABLE_COUNT}, ${SEC}s elapsed)"
        ( $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION < <(
            echo "SET SESSION tx_isolation='READ-UNCOMMITTED';SET sql_log_bin = 0;"
            $MYSQL_SRC_DUMP $MYSQL_SRC $MYDATA $CATALOG $TABLE
        ) ) &
        checkInnodbConversion
    fi
    q_push Q_TABLES_TO_CKSUM "$TABLE"
    waitForThreads
    processChecksumQueues
    INDEX=$(( $INDEX + 1 ))
done < <($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$CATALOG' AND TABLE_ROWS > 0 ORDER BY (DATA_LENGTH+INDEX_LENGTH) DESC")


if [ -n "${REPLSTOP}" ]; then
   log "Restarting slave on source..."
   $MYSQL_SRC_CLIENT $MYSQL_SRC -e "SLAVE START;"
fi

SINCE_LAST_CONVERSION=$(( $(date +%s) - $LAST_CONVERSION_START ))
if [ "$SINCE_LAST_CONVERSION" -lt "$SLEEP_BEFORE_CONVERSION" ]; then
    sleep $SLEEP_BEFORE_CONVERSION
fi

# Convert remaining MyISAM tables
LASTCHK=0
while read TABLE; do
    REMAIN=$($MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION -BNe "SELECT COUNT(1) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='${DESTINATION}' AND ENGINE='MyISAM'")
    set +e
    CONV_COUNT=$($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SHOW PROCESSLIST" | grep -c "ALTER TABLE ${DESTINATION}.${TABLE}")
    set -e
    if [ "$CONV_COUNT" -eq "0" ]; then
        SEC=$(( $(date +%s) - $TS_START ))
        log "Converting ${TABLE}... ($REMAIN remaining, ${SEC}s elapsed)"
        $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION -e "SET SESSION tx_isolation='READ-UNCOMMITTED';SET sql_log_bin = 0;SET unique_checks=0;ALTER TABLE ${DESTINATION}.${TABLE} ENGINE=InnoDB" &
    fi
    # Throttling this to account for slow conversion of small tables as we reach the end
    THISCHK=$(date +%s)
    DIFF=$(( $THISCHK - $LASTCHK ))
    if [ "$DIFF" -gt "2" ]; then
        LASTCHK=$THISCHK
        waitForThreads
        processChecksumQueues
    fi
done < <($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$DESTINATION' AND ENGINE='MyISAM' ORDER BY DATA_LENGTH DESC")

# Finish up checksums
log "Waiting for checksums to finish..."
while [ "${#Q_TABLES_TO_CKSUM[@]}" -gt "0" ] || [ "${#Q_TABLES_TO_CKSUM_TGT[@]}" -gt "0" ]; do
    processChecksumQueues
    sleep 1
done

log "Waiting for background threads to finish..."
wait



# Update percona.checksums
SEC=$(( $(date +%s) - $TS_START ))
log "Updating checksum values on target... (${SEC}s elapsed)"
echo "SET sql_log_bin = 0;" > "$SQLFILE"
echo "UPDATE percona.checksums SET master_crc=NULL, master_cnt=NULL WHERE db='${DESTINATION}';" >> "$SQLFILE"
$MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SELECT CONCAT('UPDATE percona.checksums SET master_crc=\'',master_crc,'\', master_cnt=',master_cnt,' WHERE db=\'${DESTINATION}\' AND tbl=\'',tbl,'\' AND lower_boundary',IF(ISNULL(lower_boundary),' IS NULL',CONCAT('=\'',lower_boundary,'\'')),' AND upper_boundary',IF(ISNULL(upper_boundary),' IS NULL',CONCAT('=\'',upper_boundary,'\'')),' LIMIT 1;') AS stmt FROM percona.checksums WHERE db='${CATALOG}'" >> "$SQLFILE"
$MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION < "$SQLFILE"
>"$SQLFILE"

# Find differences
TABLES_WITH_DIFFERENCES=( $($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SELECT tbl FROM percona.checksums WHERE db='${DESTINATION}' AND (master_cnt <> this_cnt OR master_crc <> this_crc OR ISNULL(master_crc) <> ISNULL(this_crc)) GROUP BY tbl;") )
if [ "${#TABLES_WITH_DIFFERENCES[@]}" -gt "0" ]; then
    SEC=$(( $(date +%s) - $TS_START ))
    log "Tables with differences: (${SEC}s elapsed)"
    log "${TABLES_WITH_DIFFERENCES[@]}"
fi



if $MAKETGTSLAVE && [ -n "$MASTER" ]; then
    # Turn doublewrite back on
    if [ "$INNODB_DOUBLEWRITE" == "OFF" ]; then
        CNF_TGT=$(find ${DATADIR_TGT}/.. -type f -name "*cnf" -exec grep -H -m1 '^innodb_doublewrite' "{}" \; | sed -e 's/:.*//')
        if [ -z "$CNF_TGT" ] || [ ! -f "$CNF_TGT" ]; then
            log "Couldn't find .cnf file to enable innodb_doublewrite"
        else
            log "Enabling innodb doublewrite..."
            sed -i 's/^innodb_doublewrite/#innodb_doublewrite/' "$CNF_TGT"
            restartTargetDB
            sleep 1
        fi
    fi
    log "Making target a replication slave of source..."
    eval $($MYSQL_SRC_CLIENT $MYSQL_SRC -BNe "SELECT CONCAT('SRCHOST=',@@hostname,' SRCPORT=',@@port)")
    eval $($MYSQL_TGT_CLIENT $MYSQL_TGT -BNe "SELECT CONCAT('TGTHOST=',@@hostname,' TGTPORT=',@@port)")
    PASSWD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | sed "$(shuf -i 1-$RANDOM -n 1)q;d")
    $MYSQL_SRC_CLIENT $MYSQL_SRC -e "GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO repl@'${TGTHOST}' IDENTIFIED BY '${PASSWD}';FLUSH PRIVILEGES;"
    sleep 0.1
    $MYSQL_TGT_CLIENT $MYSQL_TGT $DESTINATION <<-SQL
    SET sql_log_bin = 0;
    STOP SLAVE;
    CHANGE MASTER TO MASTER_HOST='${SRCHOST}', MASTER_PORT=${SRCPORT}, MASTER_USER='repl', MASTER_PASSWORD='${PASSWD}', MASTER_LOG_FILE='${SRC_MASTER_LOG_FILE}', MASTER_LOG_POS=${SRC_MASTER_LOG_POS};
    START SLAVE;
SQL
    # Loop through TABLES_WITH_DIFFERENCES and sync
    if [ "${#TABLES_WITH_DIFFERENCES[@]}" -gt "0" ]; then
        log "Syncing tables with differences..."
        for TABLE in "${TABLES_WITH_DIFFERENCES[@]}"; do
            SEC=$(( $(date +%s) - $TS_START ))
            log "Syncing ${TABLE}... (${SEC}s elapsed)"
            set +e
            pt-table-sync --verbose --execute --no-version-check --buffer-in-mysql --no-check-child-tables --no-foreign-key-checks --databases ${CATALOG} --sync-to-master h=${MYSQL_TGT_HOST},P=${MYSQL_TGT_PORT},u=${MYSQL_TGT_USER},D=${CATALOG},t=${TABLE}
            SYNC_STATUS=$?
            set -e
            if [ "$SYNC_STATUS" -eq "1" ]; then
                log "pt-table-sync internal error on table: ${TABLE}"
            fi
        done
    fi
    # Remove replication filter on percona database
    if [ "$CHECKSUM_FILTER" -gt "0" ]; then
        CNF_TGT=$(find ${DATADIR_TGT}/.. -type f -name "*cnf" -exec grep -H -m1 'replicate-wild-ignore.*percona' "{}" \; | sed -e 's/:.*//')
        if [ -z "$CNF_TGT" ] || [ ! -f "$CNF_TGT" ]; then
            log "Couldn't find .cnf file to turn off replication filter on percona db"
        else
            log "Removing replication filter on percona db..."
            sed -i '/replicate-wild-ignore.*percona/d' "$CNF_TGT"
            log "Restart the database after slave lag has caught up!"
        fi
    fi
fi

SEC=$(( $(date +%s) - $TS_START ))
log "All done. (${SEC}s elapsed)"


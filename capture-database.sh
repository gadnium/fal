#!/bin/bash

export GLIDE_DATASETS="/glide/data-sets"
export DATA_SET="$1"
export LOGFILE="${GLIDE_DATASETS}/$(date '+%Y-%m-%d-%H%M')--${DATA_SET}.capture.log"

if [ -z "${DATA_SET}" ]
then
  echo "Usage: $0 data-set-folder-name"
  exit -1
fi

export TARGET_DATASET="${GLIDE_DATASETS}/${DATA_SET}"

# Common paths.
LOGDIR="/log/mysql"
LOGDIR_BACKUP="${TARGET_DATASET}/rsync-me/log-mysql"
DATADIR="/glide/mysql/data"
DATADIR_BACKUP="${TARGET_DATASET}/rsync-me/glide-mysql/data"

# Number of threads to use for parallel rsync.
NUMBER_OF_THREADS=8
#####################################################################################################


echo "Capturing current database state to ${TARGET_DATASET} on $(date)..."           > ${LOGFILE} 2>&1
echo "Use tail -F ${LOGFILE} to monitor progress ..."
mkdir -pv ${TARGET_DATASET}/rsync-me                                                >> ${LOGFILE} 2>&1
mkdir -pv ${DATADIR_BACKUP}                                                         >> ${LOGFILE} 2>&1
mkdir -pv ${LOGDIR_BACKUP}                                                          >> ${LOGFILE} 2>&1
chown `stat --format="%U:%G" ${DATADIR}/` ${DATADIR_BACKUP}
chown `stat --format="%U:%G" ${LOGDIR}/` ${LOGDIR_BACKUP}
/sbin/service mysql stop                                                            >> ${LOGFILE} 2>&1

# How many log files need to be transferred? Only use parallel if more than NUMBER_OF_THREADS.
LOGCOUNT=`find ${LOGDIR}/ -type f | wc -l`
if [ "${LOGCOUNT}" -gt "${NUMBER_OF_THREADS}" ]; then
    cd ${LOGDIR}
    find . -type f -exec du "{}" \; | sort -nr | awk '{$1=""; print $0}' | sed "s| \./||g" | xargs -n 1 -P ${NUMBER_OF_THREADS} -I% rsync -avRP --delete "%" "${LOGDIR_BACKUP}" >> ${LOGFILE} 2>&1
else
    /usr/bin/rsync -Pav --delete ${LOGDIR}/ ${LOGDIR_BACKUP} >> ${LOGFILE} 2>&1
fi

cd ${DATADIR}
find . -type f -exec du "{}" \; | sort -nr | awk '{$1=""; print $0}' | sed "s| \./||g" | xargs -n 1 -P ${NUMBER_OF_THREADS} -I% rsync -avRP --delete "%" "${DATADIR_BACKUP}" >> ${LOGFILE} 2>&1


/bin/rm -fv ${DATADIR_BACKUP}/*.err                                                 >> ${LOGFILE} 2>&1
/sbin/service mysql start                                                           >> ${LOGFILE} 2>&1
( echo -n "$(date): Saved, " ; echo "show databases" | mysql --ssl=false -u root )  >> ${LOGFILE} 2>&1

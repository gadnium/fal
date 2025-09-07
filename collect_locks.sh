#! /bin/bash

## Data will have the following columns:
## Id User Host db Command Time State Info
##
## Id and Time will be most critical, along with Info to identify trigger.
## Remember that Array members start at position 0.

for i in $( ls /tmp/mysql*.sock ); do
   MYTEST=( `mysql -S ${i} -e "show processlist"|grep -i optimize|grep 'Waiting for table metadata lock'` )
   MYTHREAD=`echo ${MYTEST[0]}`
   MYDB=`echo ${MYTEST[3]}`
   MYTABLE=`echo ${MYTEST[13]}`

   if [ -n "${MYTEST[5]}" ] && [ "${MYTEST[5]}" -gt 60 ]; then 
      MYDATE=`date +%Y%m%d%H%M`
      mysqladmin debug
      mysql -S ${i} -e "show processlist" > /tmp/processlist.${MYDATE}
      mysql -S ${i} -e "show engine innodb status" > /tmp/engine_status.${MYDATE}
      mysql -S ${i} -e "USE INFORMATION_SCHEMA; SELECT * FROM INNODB_LOCKS WHERE LOCK_TRX_ID IN (SELECT BLOCKING_TRX_ID FROM INNODB_LOCK_WAITS)" > /tmp/blocking_locks.${MYDATE}
      mysql -S ${i} -e "USE INFORMATION_SCHEMA; SELECT * FROM INNODB_LOCKS" > /tmp/table_locks.${MYDATE}
      mysql -S ${i} -e "USE INFORMATION_SCHEMA; SELECT TRX_ID, TRX_REQUESTED_LOCK_ID, TRX_MYSQL_THREAD_ID, TRX_QUERY FROM INNODB_TRX WHERE TRX_STATE = 'LOCK WAIT'" > /tmp/lock_waits.${MYDATE}
      mysql -S ${i} -e "kill ${MYTHREAD}"
      echo "${MYDB} has hit the 'waiting for metadata lock' issues on ${MYTABLE}." | mail -s 'Locking Issue' tim.yim@servicenow.com
   fi   
done

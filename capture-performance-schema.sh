#!/bin/bash

LONG_NAMES=(events_stages_summary_global_by_event_name
            events_statements_summary_global_by_event_name
            events_waits_summary_global_by_event_name
            objects_summary_global_by_type
            table_io_waits_summary_by_index_usage
            table_io_waits_summary_by_table
            table_lock_waits_summary_by_table);

SHORT_NAMES=(stages statements waits objects io_waits_index io_waits_table lock_waits);

DBI_NAME="$1";
MYSQL="mysql -S /tmp/mysqld_${DBI_NAME}.sock -u root";

# This directory needs to be 777 so MySQL can write to it.
TARGET="/tmp";


for ((i=0; i<${#SHORT_NAMES[@]}; i++))
do
    # Capture the column names first.
    $MYSQL -BN -e "SELECT GROUP_CONCAT(CONCAT('\"',COLUMN_NAME,'\"')) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '${LONG_NAMES[$i]}' AND TABLE_SCHEMA = 'performance_schema' ORDER BY ORDINAL_POSITION;" > ${TARGET}/${SHORT_NAMES[$i]}.csv;

    # Capture the data.
    $MYSQL -e "SELECT * FROM performance_schema.${LONG_NAMES[$i]} WHERE count_star > 0 ORDER BY sum_timer_wait DESC LIMIT 100 INTO OUTFILE '${TARGET}/${SHORT_NAMES[$i]}.tmp' FIELDS TERMINATED BY ',' ENCLOSED BY '\"' LINES TERMINATED BY '\n';";

    # Append the data into the csv file.
    cat ${TARGET}/${SHORT_NAMES[$i]}.tmp >> ${TARGET}/${SHORT_NAMES[$i]}.csv
    rm -f ${TARGET}/${SHORT_NAMES[$i]}.tmp

    # Re-format the file since the numbers don't work with Excel.
    cat ${TARGET}/${SHORT_NAMES[$i]}.csv | column -t -s ',' > ${TARGET}/${SHORT_NAMES[$i]}.txt
    rm -f ${TARGET}/${SHORT_NAMES[$i]}.csv
done

# Adding the locks and mutex instances to the standard output. The column structure is different so we have a second loop.
OTHERS=(rwlock_instances mutex_instances)
for ((i=0; i<${#OTHERS[@]}; i++))
do
    # Capture the column names first.
    $MYSQL -BN -e "SELECT GROUP_CONCAT(CONCAT('\"',COLUMN_NAME,'\"')) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '${OTHERS[$i]}' AND TABLE_SCHEMA = 'performance_schema' ORDER BY ORDINAL_POSITION;" > ${TARGET}/${OTHERS[$i]}.csv;

    # Capture the data.
    $MYSQL -e "SELECT * FROM performance_schema.${OTHERS[$i]} INTO OUTFILE '${TARGET}/${OTHERS[$i]}.tmp' FIELDS TERMINATED BY ',' ENCLOSED BY '\"' LINES TERMINATED BY '\n';";

    # Append the data into the csv file.
    cat ${TARGET}/${OTHERS[$i]}.tmp >> ${TARGET}/${OTHERS[$i]}.csv
    rm -f ${TARGET}/${OTHERS[$i]}.tmp

    # Re-format the file since the numbers don't work with Excel.
    cat ${TARGET}/${OTHERS[$i]}.csv | column -t -s ',' > ${TARGET}/${OTHERS[$i]}.txt
    rm -f ${TARGET}/${OTHERS[$i]}.csv
done


# Let's also capture the basic stuff.
$MYSQL -e "SHOW GLOBAL STATUS;" > $TARGET/status.txt
$MYSQL -e "SHOW ENGINE INNODB STATUS\G" > $TARGET/innodb.txt
$MYSQL -e "SHOW ENGINE INNODB MUTEX;" > $TARGET/mutex.txt

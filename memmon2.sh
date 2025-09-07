#!/bin/bash


COLUMN=mysqlmem
#COLOR=red
#DETAIL="If you can read this, then this page actually worked."
#STATUS="TEST ALERT ONLY"

COLOR=green
DETAIL=""
STATUS="Everything OK"


# in Gb
THRESH=105
COUNT=0
SLEEP=10
LONG=60
#KILL="yes"
KILL=""

RECIPIENTS="tim.yim@servicenow.com"

while [ $COUNT -lt 1 ] ; do
  NOW=`date +%Y%m%d.%H%M%S`
  GB=`echo $(expr $(pmap -x $(cat /glide/mysql/data/$(hostname).pid) | tail -1 | awk '{print $4}') / 1024 / 1024)`

  if [ "$GB" -gt "$THRESH" ] ; then
    # snag a processlist
    mysql -e 'show full processlist' | grep -v Sleep > /glide/temp/killemall.capture.$NOW

    if [ -n "$KILL" ]; then
    #kill all selects longer than LONG
      for q in `mysql --skip-column-names -Bne "show processlist" | grep -i select | awk '{print $1 "-" $6}'`; do
          if [ "`echo $q | awk -F'-' '{print $2}'`" -gt $LONG ]; then
              killed=1;
              pid=`echo $q | awk -F'-' '{print $1}'`;
              mysql -e "kill $pid";
          fi
      done
    fi

    if [ $killed ] ; then
      echo "Allstate resident memory is at ${GB}gb, above threshold ${THRESH}gb. Last killed was $pid \n `cat /glide/temp/killemall.capture.${NOW}` " | mail -s "Allstate resident memory alert " $RECIPIENTS
        COLOR="red"
        STATUS="Resident memory at ${GB}gb (>${THRESH}gb); killed"
        DETAIL="Last killed was $pid \n `cat /glide/temp/killemall.capture.${NOW}`"
    else
      echo "Allstate resident memory is at ${GB}gb, above threshold ${THRESH}gb" | mail -s "Allstate resident memory alert " $RECIPIENTS
        COLOR="red"
        STATUS="Resident memory at ${GB}gb (>${THRESH}gb)"
    fi
  fi
  let COUNT=COUNT+1

  if [ -n "$XYMON" ] ; then
        $XYMON $XYMSRV "status+5 $MACHINE.$COLUMN $COLOR `date` - $STATUS

$DETAIL
"
  fi

  sleep $SLEEP
done

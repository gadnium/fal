#!/bin/bash

if [ x$1 == "x" ]; then
  echo "Usage: $0 <drac hostname>"
  exit
fi

#sudo /usr/libexec/PlistBuddy -c "Delete :JavaWebComponentVersionMinimum" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/XProtect.meta.plist

HOST=$1
DATE=`date '+%s'`
COOKIEFILE="cookies.$HOST.$DATE"
OUTPUTFILE="curl.out"
CMDBOUTPUTFILE="cmdb.out"
JNLPFILE="viewer.$HOST.$DATE.jnlp"

#read -p "Username: "
USER="operations"
#USER=root
#read -s -p "Password: "
#echo
PASS="28nC2kc9M4IxSI"
#PASS=calvin

if [ `echo $HOST | grep -c idrac` -eq 0 ]; then
    if [ `echo $HOST | grep -c service-now` -eq 0 ]; then
        HOST="$HOST.service-now.com"
    fi
    if [ -f $CMDBOUTPUTFILE ]; then
        rm -f $CMDBOUTPUTFILE
    fi
    /Users/tim.tim/git/sncli/sbin/sncq.py -utim.yim -p /Users/tim.tim/.sncpass -q "name=$HOST" -F serial_number > $CMDBOUTPUTFILE 2>&1
    if [ `grep -c Traceback $CMDBOUTPUTFILE` -gt 0 ]; then
        echo "failed to query CMDB for serial number for host: $HOST"
        exit
    fi
    SERIAL=`grep serial_number $CMDBOUTPUTFILE | awk '{print $3}'`
    DC=`echo $HOST | cut -d'.' -f2`
    HOST="idrac-$SERIAL.$DC.service-now.com"
    if [ -f $CMDBOUTPUTFILE ]; then
        rm -f $CMDBOUTPUTFILE
    fi
fi


if [ -f $OUTPUTFILE ]; then
    rm -f $OUTPUTFILE;
fi

echo "logging in to $HOST"
curl -s -o $OUTPUTFILE -c $COOKIEFILE -b $COOKIEFILE -d "user=$USER&password=$PASS" --insecure "https://$HOST/data/login"
if [ $? -ne 0 ]; then
    echo "failed to curl login address"
    exit
fi

if [ ! -f $OUTPUTFILE ]; then
    echo "could not find output file: $OUTPUTFILE"
    exit
fi

LOGIN=`grep -c "error" ${OUTPUTFILE}`
if [ $LOGIN -gt 0 ]; then
    echo "failed to log in"
    exit
fi

TOKEN=`cat ${OUTPUTFILE} | awk -F'html?' '{print $2}' | cut -d'=' -f2 | cut -d'<' -f1`

# Add the token cookie to the cookie file.
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s" "$HOST" "FALSE" "/" "TRUE" "0" "tokenvalue" "$TOKEN" >> $COOKIEFILE


echo "downloading jnlp"
curl -s -o $JNLPFILE -c $COOKIEFILE -b $COOKIEFILE --insecure "https://$HOST//viewer.jnlp($HOST@0@$HOST@$DATE@ST1=$TOKEN)"
if [ $? -ne 0 ]; then
    echo "failed to download jnlp file"
    exit
fi

echo "launching console"
( javaws -Xnosplash -wait $JNLPFILE; curl -s -c $COOKIEFILE -b $COOKIEFILE --insecure "https://$HOST/data/logout"; rm -f $COOKIEFILE $JNLPFILE $OUTPUTFILE ) &

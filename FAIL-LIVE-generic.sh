#!/bin/bash

## Captrure arguments
MYARGS=$@

while getopts i:s:S:t:T:c:w:m:M:gfdlxran option ; do
        case "${option}"
        in
            i) INSTANCE=${OPTARG};;
            s) SOURCEDB=${OPTARG};;
            S) SOURCEDBPORT=${OPTARG};;
            t) TARGETDB=${OPTARG};;
            T) TARGETDBPORT=${OPTARG};;
            c) CATALOG=${OPTARG};;
            w) WORKERVIP=${OPTARG};;
            g) GATEWAY=1;;
            m) MONGOHOST=${OPTARG};;
            M) MONGOPORT=${OPTARG};;
            n) NODNS=1;;
            f) FORCEFAIL=1;;
            r) RPLCHG=1;;
            d) DRYRUN=1;;
            x) DEBUG=1;;
            a) AUTOFAIL=1;;
        esac
done

## Usage:
[ -z "${INSTANCE}" ] && { echo "
Usage:
  $0 <options>

	Required:
		-i = Instance Name
	Options:
		-s = Source DB Host (fqdn please)
		-S = Source DB Port (if Host is provided and env is DBI, then this is required.)
		-t = Target DB Host (if env is down, this may be required. fqdn please)
		-T = Target DB Port (if Host is provided and env is DBI, then this is required.)
		-g = Data Gateway Enabled (Mongo support)
        -m = Mongo Host (fqdn of status host)
        -M = Mongo Port (current status host)
		-c = Catalog Name (example: ge_1 or barclays_2)
		-n = Do NOT perform any DNS updates - this will be manual
		-w = Worker VIP Name (URL - if exists)
		-f = Force Failover (Emergency - not controlled, or if you need to move a single instances froma Gen2 Shared host)
		-r = Replication Changes Needed (If CHANGE_MASTER is required))
        -d = Dry-Run (test env and validate connectivity)
        -x = Debug mode (for the shell execution)

"; exit 1; }

## Set user for failover script
FAILUSER="username"

function clean_stdin()
{
   while read -r -t 0; do read -r; done
}

## Check to see that we are running inside a script session... if not restart.
ps -ef n|grep -v grep|grep $(id -u)|grep script >> /dev/null
if [ "$?" -ne 0 ]; then
   if [ -n "${DEBUG}" ]; then
      script -c "sh -x $0 ${MYARGS}" /dev/null
   else
      script -c "$0 ${MYARGS}" /dev/null
   fi
else
   echo "Start time: `date +%F_%T`"
   if [ -z "${AUTOFAIL}" ]; then
      clean_stdin
      read -p "This script will perform a failover for ${INSTANCE}... Are you sure you want to proceed? [Press y|Y to continue] " -n 1 -r -s
   else
      REPLY="Y"
   fi
   if [[ $REPLY =~ ^[yY]$ ]]; then
      if [ -f ./screenlog.0 ];then
         rm -f ./screenlog.0
      fi
      ps -ef n|grep SCREEN|grep $(id -u)|grep -v grep >> /dev/null
      STALESCR=$?
      if [  ${STALESCR} -eq 0 ]; then
         echo "A failover is already running or possibly a stale screen session exists, please verify..."
         exit 42
      fi
      if [ -n "${DRYRUN}" ]; then
         echo -e "\E[1m\nDry-Run enabled... no actual changes will be made.\E[0m"
      fi
      ## Validate instance:
      curl -m 2 -s "https://${INSTANCE}.service-now.com/xmlstats.do?include=instance" |egrep -v 'currently unavailable|HTTP Status 403|Access restricted'  >> /dev/null
      if [ $? -ne "0" ]; then
         if [ -z "${TARGETDB}" ] && [ -z "${SOURCEDB}" ]; then
            echo -e "\nInstance is not up or is otherwise unreachable... need more info: please provide Source/Target Hosts and Catalog Name as options. Target at minimum for a failover.
   NOTE: You may also need to provide the PORT number if this is a DBI environment.\n"
            exit 1
         else
            ## Assume port 3306 is not specified.
            if [ -z "${SOURCEDBPORT}" ]; then
                SOURCEDBPORT=3306
            fi
            if [ -z "${TARGETDBPORT}" ]; then
                TARGETDBPORT=3306
            fi
            ## Get Target DB server info if it was not provided.
            if [ -z "${TARGETDB}" ] && [ -n "${SOURCEDB}" ]; then
               mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "show master status" > /dev/null 2>&1
               if [ $? -ne 0 ]; then
                    echo "Source DB is not reachable, please try setting Target DB Host and Port"
                    exit 27
               else
                    MYDBPROBE=( $( mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "show slave status\G"|grep 'Master_[HP]' |cut -d':' -f2 ) )
                    TARGETDB=$( echo ${MYDBPROBE[0]} )
                    TARGETDBPORT=$( echo ${MYDBPROBE[1]} )
               fi
            elif [ -n "${TARGETDB}" ] && [ -z "${SOURCEDB}" ]; then
                mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "show master status" > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                    echo "TARGET DB is not reachable, please verify the target you are trying to hit."
                    exit 29
                else
                    MYDBPROBE=( $( mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "show slave status\G"|grep 'Master_[HP]' |cut -d':' -f2 ) )
                    SOURCEDB=$( echo ${MYDBPROBE[0]} )
                    SOURCEDBPORT=$( echo ${MYDBPROBE[1]} )
                fi
            fi
         fi
      else
         ## Get Source DB server info, if it was not provided.
         if [ -z "${SOURCEDB}" ]; then
            MYPROBEDB=( $( curl -m 2 -s "https://${INSTANCE}.service-now.com/xmlstats.do?include=database" | sed -e 's/></>\n</g' | grep 'db.url' | cut -d'/' -f3 | cut -d':' -f1,2 | tr ':' ' ' ) )
            SOURCEDB=$( echo ${MYPROBEDB[0]} )
            SOURCEDBPORT=$( echo ${MYPROBEDB[1]} )
         fi
         ## Get Target DB server info if it was not provided.
         if [ -z "${TARGETDB}" ] || [ -z "${TARGETDBPORT}" ]; then
            MYDBPROBE=( $( mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "show slave status\G"|grep 'Master_[HP]' |cut -d':' -f2 ) )
            TARGETDB=$( echo ${MYDBPROBE[0]} )
            TARGETDBPORT=$( echo ${MYDBPROBE[1]} )
         fi
      fi

      echo -e "\nTarget DB Host is ${TARGETDB}"
      echo -e "Target DB Port is ${TARGETDBPORT}"
      echo -e "\nSource DB Host is ${SOURCEDB}"
      echo -e "Source DB Port is ${SOURCEDBPORT}"

      ## Ensure we can actually reach Target DB
      mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "show databases" > /dev/null 2>&1
      if [ "$?" != "0" ]; then
         echo -e "\nTarget DB is not reachable... please ensure Host and Port are correct."
         exit 9
      fi
      ## Determine Target datacenter and App node hosts
      if [ -n "${TARGETDB}" ]; then
         if [ -z "${CATALOG}" ]; then
            CATALOG=`curl -m 2 -s "https://${INSTANCE}.service-now.com/xmlstats.do?include=database" | sed -e 's/></>\n</g' | grep 'db.name' | cut -d '>' -f2 | cut -d '<' -f1`
            if [ -z "${CATALOG}" ]; then
               echo -e "\nInstance is not available, trying to get CATALOG name from DB..."
               CATALOG=( `mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "show databases" |grep "^${INSTANCE}"` )
               if [ -z "${CATALOG}" ]; then
                  echo -e "\nInstance is not available, please provide the CATALOG name."
                  exit 13
               elif [ ${#CATALOG[@]} -gt 1 ]; then
                  echo -e "\nInstance is not available, cannot determine catalog name... please provide this information."
                  exit 14
               else
                  echo -e "\nCatalog name is ${CATALOG}"
               fi
            else
               echo -e "\nCatalog name is ${CATALOG}"
            fi
         else
            ## Make sure Catalog actually exists on Target
            mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "show databases" |grep ${CATALOG} >> /dev/null
            if [ "$?" != "0" ]; then
               echo -e "\nTarget Catalog does not exist... please ensure Catalog name is correct."
               exit 9
            fi
         fi
         TARGETCOLO=`echo ${TARGETDB}|cut -d'.' -f2`
         echo -e "\nTarget Colo is ${TARGETCOLO}"
         ## Get Application Nodes
         echo -e "\nApp Node Hosts for ${INSTANCE} are:"
         APPNODES=( `mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "use ${CATALOG}; select system_id,schedulers from sys_cluster_state\G"|grep system_id|cut -d':' -f2|sort -u` )
         for a in ${APPNODES[@]}; do
            echo "   $a"
         done
      fi

      ## Check to see if Source DB is even alive
      if [ -z "${FORCEFAIL}" ]; then
         if [[ $(ping -c1 -W1 ${SOURCEDB}|grep received|awk '{ print $4 }') != 1 ]] ; then
            echo -e "   Source DB is not responsive, setting FORCEFAIL flag"
            FORCEFAIL=1
         fi
      fi

      ## Determine Source datacenter by stripping source host name
      if [ -n "${SOURCEDB}" ]; then
         SOURCECOLO=`echo ${SOURCEDB}|cut -d'.' -f2`
         echo -e "\nSource Colo is ${SOURCECOLO}"
      fi

      ## Determine if we have special citizens
      TARGETSPEC=`echo ${TARGETCOLO%?}`
      SOURCESPEC=`echo ${SOURCECOLO%?}`

      ## Determine Host and Port to contact
      if [ -n "${GATEWAY}" ] && [ -z "${MONGOHOST}" ]; then
         # Determine Gateway Type
         for gtype in gateways XMLStatsGateways; do
            curl -s "https://${INSTANCE}.service-now.com/xmlstats.do?include=${gtype}" |grep url > /dev/null
            if [ $? -eq "0" ]; then
               GTWAYTYPE=${gtype}
            fi
         done
         MONGO=`curl -s "https://${INSTANCE}.service-now.com/xmlstats.do?include=${GTWAYTYPE}" |sed -e 's/></>\n</g' |grep 'status.host' |cut -d'>' -f2 |cut -d'<' -f1`
         OIFS=$IFS;
         IFS=":";
         MONGO=( ${MONGO} )
         MONGOHOST=${MONGO[0]}
         MONGOPORT=${MONGO[1]}
         IFS=$OIFS;
         if [ -n "${MONGO}" ]; then
            MONGOUP=1
         fi
      elif [ -n "${GATEWAY}" ] && [ -n "${MONGOHOST}" ]; then
         if [ -z "${MONGOPORT}" ]; then
            echo "Mongo Port needs to be specified as well..."
            exit 69
         fi
         nmap -P0 -sT -p ${MONGOPORT} ${MONGOHOST} |grep open
         if [ $? == 0 ]; then
            MONGOUP=1
         fi
      fi
      if [ "${MONGOUP}" == "1" ]; then
            echo -e "\nMongo Host is: ${MONGOHOST} and Port is: ${MONGOPORT}"
         else
            echo -e "\nNo Mongo Host Identified/Detected..."
            unset GATEWAY
      fi

      echo "Checkpoint: `date +%F_%T`"
      echo -e "\nChecking slave lag on ${TARGETDB}..."
      ## Don't start unless lag is less than 2 minutes
      if [ -z "${FORCEFAIL}" ]; then
         MYSTART=1
         while [ $MYSTART -eq 1 ]; do
            MYLAG=`mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e 'show slave status\G'|grep 'Seconds_Behind'|cut -d':' -f2|tr -d '[:space:]'`
            if [[ "$MYLAG" -lt 120 || "$MYLAG" == "NULL" ]]; then
               MYSTART=0
               echo -e "\n Lag is $MYLAG secs... moving on."
            else
               echo -e "\n Lag is too high [$MYLAG]... pausing."
               sleep 10
            fi
         done
      else
         echo -e "\n Force flag was set... ignoring replication lag."
      fi

      ## Don't start unless MongoDB lag is less than 2 minutes
      echo "Checkpoint: `date +%F_%T`"
      if [ -n "${GATEWAY}" ]; then
         MONGOSTAT=1
         MONGOLAGBASE=0
         MONGOLAGCNT=0
         while [ ${MONGOSTAT} -eq "1" ]; do
            # Get gateway details for Mongo
            OIFS=$IFS;
            IFS=$'\r\n';
            MONGOCOMP=( $( ssh -oStrictHostKeyChecking=no -q -t ${FAILUSER}@${MONGOHOST} "bash -lc  \"sudo -H find / -type f -name mongo -regextype posix-egrep -regex \".\*${MONGOPORT}.*\" -exec \{\} --eval 'printjson(rs.status())' \\\;\" | egrep 'name|stateStr|optimeDate'|cut -d'\"' -f4" ) )
            IFS=$OIFS;
            # Remove the "T" from the timestamps so they can be processed by the date command
            MONGOSTANDBYSTAMP=`echo "${MONGOCOMP[2]}" | tr 'T' ' '`;
            MONGOPRIMARYSTAMP=`echo "${MONGOCOMP[5]}" | tr 'T' ' '`;
            # Convert the timestamps to seconds for comparison
            MONGOSTANDBYSECS=`date -d "${MONGOSTANDBYSTAMP}" +%s`;
            MONGOPRIMARYSECS=`date -d "${MONGOPRIMARYSTAMP}" +%s`;
            # Calculate lag based on the difference in seconds between the primary and standby timestamps
            MONGOLAG=`expr ${MONGOPRIMARYSECS} - ${MONGOSTANDBYSECS}`;
            # Check to see if either of the timestamps are empty, meaning we were unable to retrieve them. If so, exit as we do not know the current state of MongoDB replication
            if [ -z "${MONGOSTANDBYSTAMP}" ] || [ -z "${MONGOPRIMARYSTAMP}" ]; then
               echo -e "\nUnable to determine MongoDB primary or standby timestamp for replication lag check. Exiting..."
               exit 2
            fi
            # If lag is <120 seconds, continue. If lag is >=120 seconds and <300 seconds, wait for it to catch up. If lag is >=300 seconds, it's borked, so exit
            if [ ${MONGOLAG#-} -lt "120" ]; then
               echo -e "\nMongo Hosts are In-Sync (currently ${MONGOLAG} seconds behind...)"
               MONGOSTAT=0
            # if lag goes up or stays the same, increase the count. If lag goes down, do nothing. If the count reaches 3, exit
            elif [ ${MONGOLAG#-} -lt "300" ] && [ ${MONGOLAGCNT} -lt "3" ]; then
               echo -e "\nMongo is out of sync by ${MONGOLAG} seconds... pausing to try again."
               if [ ${MONGOLAG#-} -ge ${MONGOLAGBASE} ]; then
                  MONGOLAGCNT=`expr ${MONGOLAGCNT} + 1`
               fi
               MONGOLAGBASE=${MONGOLAG}
               sleep 5
            else
               echo -e "\nMongo is too far out of sync to continue (currently ${MONGOLAG} seconds behind)... exiting."
               exit 2
            fi
         done
      fi

      if [ -z "${NODNS}" ]; then
         if [ "${SOURCECOLO}" != "${TARGETCOLO}" ] && [ -n "${TARGETCOLO}" ]; then
            echo -e "\E[1m\nRepointing Instance URL to ${TARGETCOLO}...\E[0m"
            if [ -n "${DRYRUN}" ]; then
               echo -e "\nNot REALLY!!!"
               screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@dnshost "echo ${INSTANCE} ${TARGETCOLO}"
               if [ -n "${WORKERVIP}" ]; then
                  echo -e "   Repointing Worker URL to ${TARGETCOLO}..."
                  screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@dnshost "echo ${WORKERVIP} ${TARGETCOLO}"
               fi
            else
               screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@dnshost "<command to change DNS to target datacenter>"
               if [ -n "${WORKERVIP}" ]; then
                  echo -e "   Repointing Worker URL to ${TARGETCOLO}..."
                  screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@dnshost "<command to change WORKERVIP DNS to target datacenter>"
               fi
            fi
         else
            echo -e "\nTarget Colo is the same as the Source.  No DNS change required"
         fi
      else
         echo -e "\E[1m\nDNS changes will need to be manually input for 'special' VIP.\E[0m"
      fi

      echo "Checkpoint: `date +%F_%T`"
      echo -e "\E[1m\nShutdown ${INSTANCE} Nodes, Fast Fail File Management and Update 'glide.db.properties' for ${TARGETDB}...\E[0m"
      for i in ${APPNODES[@]}; do
         if [ -n "${DRYRUN}" ]; then
            echo -e "\nNot really doing it."
            if [[ "${i}" != *"${TARGETSPEC}"* ]]; then
               if [[ $(ping -c1 -W1 ${i}|grep received|awk '{ print $4 }') == 1 ]] ; then
                  echo -e "   Adding maintenance file to source nodes on ${i}"
                  screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} "bash -lc '(cd /; ls)'"
                  echo "If not a dry-run, would execute:"
                  echo "ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} \"bash -lc '(for j in ${INSTANCE}[0-9][0-9][0-9]_*; do sudo stop.sh \`basename \${j}\` & ; sudo touch \${j}/webapps/glide/itil/snc_down_node.html; sudo /bin/cp -f \${j}/conf/glide.db.properties \${j}/conf/glide.db.properties.`date +%Y%m%d%H%M`; sudo /bin/sed -i 's/db[0-9].*.service-now.com:${SOURCEDBPORT}/${TARGETDB}:${TARGETDBPORT}/' \${j}/conf/glide.db.properties; done; sudo snc-appnode -S -a setfailover -r failover; wait)'\""
               else
                  echo -e "   Host ${i} is unreachable."
               fi
            elif [[ "${i}" == *"${TARGETSPEC}"* ]]; then
               echo -e "   Removing maintenance file to target nodes on ${i}"
               screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} "bash -lc '(cd /; ls)'"
               echo "If not a dry-run, would execute:"
               echo "ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} \"bash -lc '(for j in ${INSTANCE}[0-9][0-9][0-9]_*; do sudo stop.sh \`basename \${j}\` & ; sudo rm -f \${j}/webapps/glide/itil/snc_down_node.html; sudo /bin/cp -f \${j}/conf/glide.db.properties \${j}/conf/glide.db.properties.`date +%Y%m%d%H%M`; sudo /bin/sed -i 's/db[0-9].*.service-now.com:${SOURCEDBPORT}/${TARGETDB}:${TARGETDBPORT}/' \${j}/conf/glide.db.properties; done; sudo snc-appnode -S -a setfailover -r failover; wait)'\""
            fi
         else
            if [[ "${i}" != *"${TARGETSPEC}"* ]]; then
               if [[ $(ping -c1 -W1 ${i}|grep received|awk '{ print $4 }') == 1 ]] ; then
                  echo -e "   Adding maintenance file to source nodes on ${i}"
                  screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} "bash -lc '(for j in ${INSTANCE}[0-9][0-9][0-9]_*; do sudo stop.sh \`basename \${j}\` & ; sudo touch \${j}/webapps/glide/itil/snc_down_node.html; sudo /bin/cp -f \${j}/conf/glide.db.properties \${j}/conf/glide.db.properties.`date +%Y%m%d%H%M`; sudo /bin/sed -i 's/db[0-9].*.service-now.com:${SOURCEDBPORT}/${TARGETDB}:${TARGETDBPORT}/' \${j}/conf/glide.db.properties; done; sudo snc-appnode -S -a setfailover -r failover; wait)'"
               else
                  echo -e "   Host ${i} is unreachable."
               fi
            elif [[ "${i}" == *"${TARGETSPEC}"* ]]; then
               echo -e "   Removing maintenance file to target nodes on ${i}"
               screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} "bash -lc '(for j in ${INSTANCE}[0-9][0-9][0-9]_*; do sudo stop.sh \`basename \${j}\` &; sudo rm -f \${j}/webapps/glide/itil/snc_down_node.html; sudo /bin/cp -f \${j}/conf/glide.db.properties \${j}/conf/glide.db.properties.`date +%Y%m%d%H%M`; sudo /bin/sed -i 's/db[0-9].*.service-now.com:${SOURCEDBPORT}/${TARGETDB}:${TARGETDBPORT}/' \${j}/conf/glide.db.properties; done; sudo snc-appnode -S -a setfailover -r failover; wait)'"
            fi
         fi
      done

      echo "Checkpoint: `date +%F_%T`"
      if [ -n "${GATEWAY}" ]; then
         echo -e "\nGateway is set, including Mongo..."

         if [ ${MONGOCOMP[1]} == "PRIMARY" ] && [ ${MONGOCOMP[4]} == "SECONDARY" ]; then
            MONGOSRC=${MONGOCOMP[0]}
            MONGODST=${MONGOCOMP[3]}
         elif [ ${MONGOCOMP[1]} == "SECONDARY" ] && [ ${MONGOCOMP[4]} == "PRIMARY" ]; then
            MONGOSRC=${MONGOCOMP[3]}
            MONGODST=${MONGOCOMP[0]}
         fi

         echo -e "\nMongo Source is ${MONGOSRC} and Target is ${MONGODST}"
         # Sanity check for MySQL/Mongo Colo
         MYSQLCOLO=$( echo ${SOURCEDB} | cut -d'.' -f2 )
         MONGOCOLO=$( echo ${MONGOSRC} |cut -d'.' -f2 )
         if [ "${MYSQLCOLO}" != "${MONGOCOLO}" ]; then
            echo "MySQL and Mongo DO NOT live in the same colo."
            clean_stdin
            read -p "Do you want to perform Mongo transfer anyway? [Press Y to continue] " -n 1 -r -s
            if [[ $REPLY =~ ^[Y]$ ]]; then
               DOMONGOFAIL=1
            fi
         else
            echo "MySQL and Mongo live in ${MYSQLCOLO}"
            DOMONGOFAIL=1
         fi

         # Stuff for failover
         if [ -n "S{DOMONGOFAIL}" ]; then
            echo -e "\nFailing over Mongo...\n"
            if [ -n "${DRYRUN}" ]; then
               # Call dry-run test of mongodb transfer command
               MONGOFAILPROG=1
            else
               # Call command to transfer primary mongodb instance
               MONGOFAILPROG=1
            fi
         else
            echo "Skipping Mongo Failover!"
            MONGOFAILPROG=0
         fi
      else
         echo -e "\nGateway not set, skipping Mongo..."
         MONGOFAILPROG=0
      fi

      ### Checking for SQL Shards
      echo "Checking for SQL Shards..."
      if [ -n "${DRYRUN}" ]; then
          echo -e "\nNot really doing it."
      else
          gateway_config_exists=`mysql -s -N -D ${CATALOG} -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "show tables like 'gateway_config'"`
          if [ "$gateway_config_exists" = "gateway_config" ]; then
              count_sql_gateway=`mysql -s -N -D ${CATALOG} -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "select count(1) from gateway_config where type='sql'"`
              if [ "$count_sql_gateway" -gt "0" ]; then
                  echo "Checkpoint: `date +%F_%T`"
                  echo "SQL Shards exists..Failing the over now....."
                  sql_gateways=$(mysql -s -BN -D ${CATALOG} -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "SELECT TRIM(REPLACE(url,'\n','')) FROM gateway_config WHERE type='sql'")
                  for GW in $sql_gateways; do
                      GW1=${GW%%,*}
                      GW2=${GW##*,}
                      if [[ $GW2 =~ $SOURCECOLO ]]; then
                        TMP=$GW1
                        GW1=$GW2
                        GW2=$TMP
                      fi
                      SHARDDB=${GW1#*//}
                      SHARDDB=${SHARDDB%:*}
                      SHARDDBPORT=${GW1##*:}
                      SHARDDBPORT=${SHARDDBPORT%/*}
                      if [ "$GW1" != "$GW2" ]; then
                          SHARDDB2=${GW2#*//}
                          SHARDDB2=${SHARDDB2%:*}
                          SHARDDBPORT2=${GW2##*:}
                          SHARDDBPORT2=${SHARDDBPORT2%/*}
                      fi
                      echo "set Shards with proper RW,RO.."
                      echo -e "\nChecking slave lag on ${SHARDDB2}..."
                      ## Don't start unless lag is less than 2 minutes
                      if [ -z "${FORCEFAIL}" ]; then
                          MYSTART=1
                          while [ $MYSTART -eq 1 ]; do
                              MYLAG=`mysql -h ${SHARDDB2} -P ${SHARDDBPORT2} -e 'show slave status\G'|grep 'Seconds_Behind'|cut -d':' -f2|tr -d '[:space:]'`
                              if [[ "$MYLAG" -lt 120 || "$MYLAG" == "NULL" ]]; then
                                  MYSTART=0
                                  echo -e "\n Lag is $MYLAG secs... moving on."
                              else
                                  echo -e "\n Lag is too high [$MYLAG]... pausing."
                                  sleep 10
                              fi
                          done
                      else
                          echo -e "\n Force flag was set... ignoring replication lag."
                      fi
                      echo -e "Setting ${SHARDDB2} to RW and ${SHARDDB} to RO."
                      mysql -h ${SHARDDB} -P ${SHARDDBPORT} -e "set global read_only=1;" & wait
                      mysql -h ${SHARDDB2} -P ${SHARDDBPORT2} -e "set global read_only=0;" & wait
                  done  ## done for loop
              fi ## Enf of if SQL gateway exists
          fi # End of Check if gateway table exists
      fi ## Endif for dryrun
      ### ENd of SQL Shards


      echo "Checkpoint: `date +%F_%T`"
      if [ -n "${DRYRUN}" ]; then
         echo -e "\nGet ${SOURCEDB} Read-Only State..."
         if [ -z "${FORCEFAIL}" ]; then
            mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "show global variables like 'read_only';" & wait
            echo "   Checking for long running SELECTs on ${SOURCEDB}"
            for PLIST in `mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e 'show processlist'|grep SELECT |awk '{ print $1 }'`; do
               echo "Not really killing long running select ${PLIST}"
            done
         fi
         echo -e "\nGet ${TARGETDB} Read-Only State..."
         mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "show global variables like 'read_only';" & wait
         echo -e "\nGet schedulers in sys_cluster_state for Target colo: ${TARGETCOLO}"
         mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "use ${CATALOG}; select system_id,schedulers,status from sys_cluster_state;"
      else
         if [ -z "${FORCEFAIL}" ]; then
            echo -e "\nSetting ${SOURCEDB} to Read-Only..."
            mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "set global read_only=1;" &
            echo "   Killing any long running SELECTs on ${SOURCEDB}"
            for PLIST in `mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e 'show processlist'|grep SELECT |awk '{ print $1 }'`; do
               mysql -h ${SOURCEDB} -P ${SOURCEDBPORT} -e "kill query ${PLIST}"
            done
         fi
         wait
         echo -e "\nSetting ${TARGETDB} to Read-Write..."
         mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "set global read_only=0;" & wait
         echo -e "\nSet schedulers in sys_cluster_state for active colo: ${TARGETCOLO}"
         mysql -h ${TARGETDB} -P ${TARGETDBPORT} -e "use ${CATALOG}; update sys_cluster_state set schedulers = 'specified' where system_id like '%${SOURCESPEC}%'; update sys_cluster_state set schedulers = 'any' where system_id like '%${TARGETSPEC}%';"
      fi

      echo -e "\nValidate shutdown and updates have completed on App nodes..."
      RUNNINGNODE=0
      while [ ${RUNNINGNODE} -eq 0 ]; do
         ps -ef n|grep SCREEN|grep $(id -u)|grep -v grep >> /dev/null
         RUNNINGNODE=$?
         sleep 1
      done

      if [ -n "${RPLCHG}" ]; then
         echo "Checkpoint: `date +%F_%T`"
         echo " "
         clean_stdin
         REPLY=0
         while [ "$REPLY" != "C" ]; do
            read -p  "Execute any \"CHANGE MASTER\" statements now.  Hit [Shift-C] key to continue... " -n 1 -r -s
            if [ "$REPLY" != "C" ]; then
                echo "If you want to exit/abort the script, press 'Control-C' to break."
            fi
         done
         echo -e "\E[1m\nContinuing...\E[0m"
      fi

      echo "Checkpoint: `date +%F_%T`"
      echo -e "\E[1m\nStarting ${INSTANCE} App Nodes...\E[0m"
      if [ -n "${DRYRUN}" ]; then
         for i in ${APPNODES[@]}; do
            screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} "bash -lc '(for j in ${INSTANCE}[0-9][0-9][0-9]_*; do echo \${j}; done)'"
            echo "Not Really Starting ${i}"
         done
      else
        for i in ${APPNODES[@]}; do
           if [[ $(ping -c1 -W1 ${i}|grep received|awk '{ print $4 }') == 1 ]] ; then
              screen -L -d -m ssh -oStrictHostKeyChecking=no -t ${FAILUSER}@${i} "bash -lc '(for j in ${INSTANCE}[0-9][0-9][0-9]_*; do sudo start.sh \`basename \${j}\`; done; wait)'"
              echo "   Starting app nodes on ${i}"
           else
              echo -e "   Host ${i} is unreachable."
           fi
        done
      fi

      echo "Checkpoint: `date +%F_%T`"
      echo -e "\nValidate nodes startup has completed..."
      RUNNINGNODE=0
      while [ $RUNNINGNODE -eq 0 ]; do
         ps -ef n|grep SCREEN|grep $(id -u)|grep -v grep >> /dev/null
         RUNNINGNODE=$?
         sleep 1
      done

      if [ ${MONGOFAILPROG} -eq "1" ]; then
         ###   VERIFY MONGO FAILOVER COMPLETE   ###
         MONGOVER=1
         while [ ${MONGOVER} -eq "1" ]; do
            OIFS=$IFS;
            IFS=$'\r\n';
            MONGOFAIL=( $( ssh -oStrictHostKeyChecking=no -q -t ${FAILUSER}@${MONGOHOST} "bash -lc  'sudo -H bash -lc \"/path/to/mongo --eval printjson\(rs.status\(\)\)\"' | egrep 'name|stateStr|optimeDate'|cut -d'\"' -f4" ) )
            IFS=$OIFS;
            if  [ "${MONGOCOMP[1]}" == "${MONGOFAIL[4]}" ] && [ "${MONGOCOMP[4]}" == "${MONGOFAIL[1]}" ]; then
               echo -e "\nMongo failover complete..."
               MONGOVER=0
            else
               echo -e "\nWaiting for Mongo failover to complete..."
               sleep 2
               if [ -n "${DRYRUN}" ]; then
                  echo -e "\nMongo failover complete..."
                  MONGOVER=0
               fi
            fi
         done
      fi

      echo -e "\E[1m\nAll done... please validate!\n\E[0m"
      echo "End time: `date +%F_%T`"
   else
      echo -e "\E[1m\nExiting!\n\E[0m"
      echo "End time: `date +%F_%T`"
      exit 1
   fi
fi

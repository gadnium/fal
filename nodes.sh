#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <app instance>"
  exit
fi

source ~/bin/utils.sh

DB_PRIMARY=()
DB_STANDBY=()
DB_RR=()

echo "Querying..."

TEMP=$(call_sncq -t cmdb_ci_service_now -q "name=$1" -F instance_id)
[[ "$TEMP" == *Traceback* ]] && echo "******** ERROR ********" && echo $TEMP && echo "Hmmmm... instance name fail?" && exit 1;
INSTANCE_ID=${TEMP##* }

echo $INSTANCE_ID

NAME=()
HOST=()
PORT=()
SCHEDULER=()
DB=()
NODE_TYPE=()

TEMP=$(call_sncq -t service_now_node -q "instance_id=${INSTANCE_ID}^operational_status=1" -F "name u_host u_discovered_node_port u_disco_scheduler_state u_db_url u_node_type sys_id" -k sys_id)
[[ "$TEMP" == *Traceback* ]] && echo "******** ERROR ********" && echo $TEMP && exit 1;
while read LINE; do
	if [[ "$LINE" == *=\>* ]]; then
		VAL=${LINE##* }
		case "$LINE" in
			*name*) NAME+=("$VAL") VAL="" ;;
			*u_host*) HOST+=("$VAL") VAL="" ;;
			*u_discovered_node_port*) PORT+=("$VAL") VAL="" ;;
			*u_disco_scheduler_state*) SCHEDULER+=("$VAL") VAL="" ;;
			*u_db_url*) DB+=("$VAL") VAL="" ;;
			*u_node_type*) NODE_TYPE+=("$VAL") VAL="" ;;
		esac
		continue
	fi
done < <(echo "$TEMP")

OUT=()
TEMP="Node Host Port Type Scheduler DBUrl"
OUT+=("$TEMP")
for i in ${!PORT[*]}; do
	TEMP=""
	TEMP="${NAME[$i]}"
	TEMP="${TEMP} ${HOST[$i]}"
	TEMP="${TEMP} ${PORT[$i]}"
	TEMP="${TEMP} ${NODE_TYPE[$i]}"
	TEMP="${TEMP} ${SCHEDULER[$i]}"
	TEMP="${TEMP} ${DB[$i]}"
	OUT+=("$TEMP")
done

printf '%s\n' "${OUT[@]}" | column -t

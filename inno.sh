#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <app instance>"
  exit
fi

call_sncq() {
	RET=$(/Users/tim.tim/git/sncli/sbin/sncq.py -utim.yim -p /Users/tim.tim/.sncpass $@ 2>&1)
	echo "$RET"
}

DB_PRIMARY=()
DB_STANDBY=()
DB_RR=()

function innotop2clipboard {
	local PORT=${1#*:}
	[[ "$PORT" ]] && echo -n "innotop --delay 1 --mode Q --socket /tmp/mysqld*${PORT}.sock" | pbcopy
}

echo "Querying..."

TEMP=$(call_sncq -t cmdb_ci_service_now -q "name=$1" -F instance_id)
[[ "$TEMP" == *Traceback* ]] && echo "******** ERROR ********" && echo $TEMP && echo "Hmmmm... instance name fail?" && exit 1;
INSTANCE_ID=${TEMP##* }

TEMP=$(call_sncq -t cmdb_ci_db_catalog -q "u_discovered_instance_id=${INSTANCE_ID}^operational_status=1" -F "database_instance" -k sys_id)
[[ "$TEMP" == *Traceback* ]] && echo "******** ERROR ********" && echo $TEMP && exit 1;
QUERY=$(echo "$TEMP" | fgrep @ | sed -e 's/.*=> //' | tr '\n' ',')
QUERY=${QUERY%,}

TEMP=$(call_sncq -t cmdb_ci_db_mysql_instance -q "nameIN${QUERY}" -F "u_usage")
[[ "$TEMP" == *Traceback* ]] && echo "******** ERROR ********" && echo $TEMP && exit 1;
while read LINE; do
	if [[ "$LINE" == MySQL* ]]; then
		THIS_MYSQL="$LINE"
		THIS_MYSQL=${THIS_MYSQL#*@}
		continue
	fi
	if [[ "$LINE" == *u_usage* ]] && [ ! -z "$THIS_MYSQL" ]; then
		case "$LINE" in
			*Replica*) DB_RR+=("$THIS_MYSQL") THIS_MYSQL="" ;;
			*Primary*) DB_PRIMARY+=("$THIS_MYSQL") THIS_MYSQL="" ;;
			*Standby*) DB_STANDBY+=("$THIS_MYSQL") THIS_MYSQL="" ;;
		esac
	fi
done < <(echo "$TEMP")

case $0 in
	*"pri"*)
		innotop2clipboard $DB_PRIMARY
		jmp ${DB_PRIMARY%:*}
		exit
		;;
	*"sby"*)
		innotop2clipboard $DB_STANDBY
		jmp ${DB_STANDBY%:*}
		exit
		;;
	*"rr"* )
		innotop2clipboard $DB_RR
		jmp ${DB_RR%:*}
		exit
		;;
esac

CHOICES=()
CHOICE=""
INDEX=1

echo "Primary:"
printf "%5s) %36s\n" $INDEX "${DB_PRIMARY[@]}"
CHOICES+=(${DB_PRIMARY[@]})
(( INDEX++ ))

if [ "${#DB_STANDBY[@]}" -gt "0" ]; then
	echo "Standby:"
	printf "%5s) %36s\n" $INDEX "${DB_STANDBY[@]}"
	CHOICES+=(${DB_STANDBY[@]})
	(( INDEX++ ))
fi

if [ "${#DB_RR[@]}" -gt "0" ]; then
	echo "RR:"
	for RR in "${DB_RR[@]}"; do
		printf "%5s) %36s\n" $INDEX $RR
		CHOICES+=($RR)
		(( INDEX++ ))
	done
fi

CHOICES+=("Q")
printf "%5s) Quit\n" "Q"
while read -rp "Connect to: " SEL && [[ "$SEL" ]]; do
	[ "$SEL" == "Q" ] && break
	[[ "$SEL" != *[![:digit:]]* ]] && (( $SEL > 0 && SEL <= ${#CHOICES[@]} )) || {
		echo "Invalid option: $SEL";
		continue
	}
	((SEL--))
	CHOICE=${CHOICES[$SEL]}
	innotop2clipboard $CHOICE
	CHOICE=${CHOICE%:*}
	echo "You chose: $CHOICE"
	break
done

if [ ! -z "$CHOICE" ]; then
	jmp $CHOICE
fi


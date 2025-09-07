#!/bin/bash
# TY-09/10/14: This is a POC for queue based processing in bash with feedback
# to the controlling script (this one) handled via named pipe.
# Has abstract (configurable) queue handling/management so if queue names
# change or more stages are added, it shouldn't require too much invasive
# change through the controlling script.

# Be strict
set -e
set -u
export PS4='+$BASH_SOURCE:$LINENO:${FUNCNAME:-main}(): '

# How wide should processing individual work units be done
THREADS=8

# Filler bogus work items
TODO=($(seq 1 200))

# The queues through which the items above will flow (in order)
QUEUES=("STAGE1" "STAGE2" "STAGE3" "STAGE4" "STAGE5")

# Sanity check queue names
UQCNT=$(printf "%s\n" "${QUEUES[@]}" | sort -u | grep -c '^')
if [ "$UQCNT" -lt "${#QUEUES[@]}" ]; then
    echo "Queue names must be unique!"
    exit 1
fi


# Initialize the queues
QINIT=""
for Q in ${QUEUES[@]}; do
    QINIT="${QINIT} $Q=() ${Q}_REDO=()"
done
eval "$QINIT"

# A place to store the items after they've been through the queues
FINISHED=()

# How many running processes there are. We know how many we fire off so
# incrementing here is no problem. We supposedly know when they exit
# via feedback so decrementing here shouldn't be a problem either.
RUNNING=0

# Setup the named pipe through which we'll get feedback from subprocesses
MYPIPE=$(mktemp -qu /glide/tmp/mypipe.XXXXXXXXXX)
mkfifo --mode=600 "$MYPIPE"
sleep 0.1
exec 4<> "$MYPIPE"

# Cleanup on exit
function handleEXIT {
    kill $(jobs -p) 2>/dev/null
    exec 4>&-
    rm -f "$MYPIPE"
    exit
}
trap handleEXIT EXIT



# Queue management functions
function q_push { eval "${1}+=(\"$2\")"; }
function q_pop { eval "${1}=(${1[@]:0:$((${#1[@]}-1))})"; }
function q_shift { eval "${1}=(\"\${$1[@]:1}\")"; }
function q_unshift { eval "${1}=($2 "${1[@]}")"; }
function del_q_idx { eval "${1}=(\${$1[@]:0:$2} \${$1[@]:$(($2 + 1))})"; }
function q_del {
    local c i v
    eval "c=\${#$1[@]}"
    for (( i=0; i<$c; i++ )); do
        eval "v=\${$1[$i]}"
        [ "$2" = "$v" ] && break
    done
    del_q_idx "$1" "$i"
}


# A function to show status of items flowing through the queues to be called while
# while work proceeds
function printStatus {
    STATUS=""
    for Q in ${QUEUES[@]} FINISHED; do
        STATUS=${STATUS}' echo "'$Q'=${#'$Q'[@]:+0} items";'
    done
    eval "$STATUS"
}

# A function to process a message delivered from a subshell and either move the work
# item to the next queue, or to the redo queue if success not detected.
function processMessage {
    local STAGE=${1#*:}
    STAGE=${STAGE%%:*}
    local QITEM=${1##*:}
    local i v
    for (( i=0; i<${#QUEUES[@]}; i++ )); do
        eval "v=\${QUEUES[$i]}"
        [[ "$v" == "$STAGE" ]] && break
    done
    NEXT_IDX=$(( $i + 1 ))
    [ "$NEXT_IDX" -eq "${#QUEUES[@]}" ] && NEXT_Q="FINISHED" || NEXT_Q=${QUEUES[$NEXT_IDX]}
    [[ $1 == *Success* ]] && q_push $NEXT_Q $QITEM || q_push ${QUEUES[$i]}_REDO $QITEM
}

# A function that will start an individual work item in a subshell
function startChild {
    local SLEEPVAL=$(( $RANDOM % ${#TODO[@]} ))
    SLEEPVAL=0.1
    local MSG=""
    [ $(( $RANDOM % 100 )) -lt 2 ] && MSG="Failed" || MSG="Success"
    echo "Starting child $1 for $SLEEPVAL which will exit: $MSG"
    ( sleep $SLEEPVAL && echo "Child $BASHPID exiting... $MSG:$2:$1" >> "$MYPIPE" ) &
    RUNNING=$(( $RUNNING + 1 ))
}

# The workhorse function that looks at items in queues and starts them processing
function processQueues {
    for Q in ${QUEUES[@]}; do
        eval 'Q_COUNT_REDO=${#'$Q'_REDO[@]}'
        while [ "$RUNNING" -lt "$THREADS" ] && [ "$Q_COUNT_REDO" -gt "0" ]; do
            eval 'ITEM=${'$Q'_REDO[0]}'
            echo "Redoing $Q for $ITEM"
            startChild "$ITEM" "$Q"
            q_del ${Q}_REDO $ITEM
            eval 'Q_COUNT_REDO=${#'$Q'_REDO[@]}'
        done
        eval 'Q_COUNT=${#'$Q'[@]}'
        while [ "$RUNNING" -lt "$THREADS" ] && [ "$Q_COUNT" -gt "0" ]; do
            eval 'ITEM=${'$Q'[0]}'
            echo "Starting $Q for $ITEM"
            startChild "$ITEM" "$Q"
            q_del $Q "$ITEM"
            eval 'Q_COUNT=${#'$Q'[@]}'
        done
    done
}


# Start by moving all work items into the first queue
for i in ${TODO[@]}; do
    q_push ${QUEUES[0]} $i
done

# The main loop which does the following:
# * Looks for feedback from subshells and deals with it
# * Looks to see if all work is complete so it can exit
# * Calls functions to handle processing and report status
while true; do
    while read -t 0.2 -ru 4 line; do
        if [ -n "$line" ] && [[ $line == *exiting* ]]; then
            RUNNING=$(( $RUNNING - 1 ))
            processMessage "$line"
            unset line
        fi
    done
    if [ "$RUNNING" -lt "1" ] && [ "${#TODO[@]}" -eq "${#FINISHED[@]}" ]; then
        echo "Work appears complete!"
        break
    fi
    processQueues
    printStatus
    sleep 0.25
done

# Finish up
echo "To do: ${TODO[@]}"
echo "Finished: ${FINISHED[@]}"
